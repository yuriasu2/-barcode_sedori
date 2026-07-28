'use strict';

const crypto = require('crypto');

const { MiniRouter } = require('./miniRouter');
const { convertCode, CODE_TYPES } = require('./instore/convert');
const { LruCache } = require('./cache');
const pricing = require('./spapi/pricing');
const spapiAuth = require('./spapi/auth');
const oauth = require('./oauth');
const keepa = require('./keepa/client');
const deviceRateLimit = require('./deviceRateLimit');
const listings = require('./spapi/listings');
const spapiClient = require('./spapi/client');

/**
 * 無料プランのデバイス単位・日次バックストップ上限。
 * クライアントの100件/日より高め(手動検索・リトライを吸収し誤ブロックを避ける)。
 * env FREE_DEVICE_DAILY_LIMIT で上書き可能。
 */
const FREE_DEVICE_DAILY_LIMIT = parseInt(process.env.FREE_DEVICE_DAILY_LIMIT, 10) || 150;

const searchCache = new LruCache();
const offersCache = new LruCache();
const graphCache = new LruCache({ ttlMs: 60 * 60 * 1000, maxSize: 200 }); // グラフ画像: 1時間キャッシュ

/**
 * Keepa経路の結果は長め(30分)にキャッシュする。
 * KeepaはサーバーのAPIキー(共有コスト・トークン制)を消費するため、
 * 同一コードの再検索での再取得を抑える。SP-API経路はBYO(各自の枠)のため既定TTL(5分)のまま。
 */
const KEEPA_CACHE_TTL_MS = 30 * 60 * 1000;

const router = new MiniRouter();

// Amazon.co.jp本体のセラーID。出品者一覧でAmazon自身の在庫を判別するために使う
// (実データで確認: 販売元がAmazon.co.jpの商品ページにこのmerchantIdが出現する)。
const AMAZON_JP_SELLER_ID = 'AN1VRQENFRJN5';

const SPAPI_CREDENTIALS_MISSING_MESSAGE = 'SP-API連携またはサーバーのKeepa設定が必要です';
const PLAN_REQUIRED_MESSAGE = 'この機能はProプランでご利用いただけます。';
const SPAPI_LINK_REQUIRED_MESSAGE = '出品にはSP-API連携が必要です。設定タブでAmazon連携を行ってください。';
const SELLER_ID_REQUIRED_MESSAGE = '出品にはAmazon連携のやり直しが必要です。設定タブでAmazon連携を行い直してください。';

/**
 * 出品系APIが受理するconditionType(Listings Items APIのcondition_type値)。
 * アプリの出品フォームと同じ5種(新品+中古4種)を受理する。
 */
const LISTING_CONDITION_TYPES = [
  'new_new',
  'used_like_new',
  'used_very_good',
  'used_good',
  'used_acceptable',
];

/**
 * アプリが自己申告するプランを判定する(フリーミアム Phase 1: X-App-Plan ヘッダー)。
 * 'pro' のときのみ true。ヘッダー無し/その他は無料(false)扱い(安全側)。
 * ※自己申告のためPhase 2でサーバー側レシート検証(App Store Server API)に置き換える。
 */
function isProRequest(headers) {
  const plan = headers && (headers['x-app-plan'] || headers['X-App-Plan']);
  return String(plan || '').toLowerCase() === 'pro';
}

/**
 * 出品系API共通ゲート: Pro + BYOトークン(X-Spapi-Refresh-Token)+ sellerId(X-Spapi-Seller-Id)必須。
 * .envのLWA_REFRESH_TOKENにはフォールバックしない(他人のsellerで出品してしまう事故防止)。
 * sellerIdはSellers APIには含まれず取得不可能なため、OAuth認可時のコールバック
 * (selling_partner_id)でアプリが受け取り保持した値をこのヘッダーで送ってもらう方式にしている。
 * 通過時はsellerId込みのcredentialsを返し、弾いた場合はresへ403/503を書き込んでnullを返す。
 */
function requireProByoCredentials(req, res) {
  if (!isProRequest(req.headers)) {
    res.status(403).json({ error: 'plan_required', message: PLAN_REQUIRED_MESSAGE });
    return null;
  }
  const headerToken =
    req.headers && (req.headers['x-spapi-refresh-token'] || req.headers['X-Spapi-Refresh-Token']);
  if (!headerToken) {
    res.status(403).json({ error: 'spapi_link_required', message: SPAPI_LINK_REQUIRED_MESSAGE });
    return null;
  }
  const credentials = resolveSpApiCredentials(req.headers);
  if (!credentials) {
    // clientId/clientSecret未設定(サーバー構成不備)。
    res.status(503).json({ error: 'spapi_credentials_missing', message: SPAPI_CREDENTIALS_MISSING_MESSAGE });
    return null;
  }
  const sellerId =
    req.headers && (req.headers['x-spapi-seller-id'] || req.headers['X-Spapi-Seller-Id']);
  if (!sellerId) {
    res.status(403).json({ error: 'seller_id_required', message: SELLER_ID_REQUIRED_MESSAGE });
    return null;
  }
  return { ...credentials, sellerId };
}

/**
 * Listings Restrictions API応答をアプリ向けに要約する。
 * restrictionsが1件でもあれば制限あり。理由メッセージは全件を改行連結し、
 * 解除申請リンクは最初に見つかったlinks[].resourceを使う。
 */
function summarizeRestrictions(response) {
  const restrictions = (response && response.restrictions) || [];
  if (!Array.isArray(restrictions) || !restrictions.length) {
    return { restricted: false, message: null, approvalUrl: null };
  }
  const reasons = restrictions.flatMap((r) => (r && r.reasons) || []);
  const messages = reasons.map((r) => r && r.message).filter(Boolean);
  const links = reasons.flatMap((r) => (r && r.links) || []);
  const firstLink = links.find((l) => l && l.resource);
  return {
    restricted: true,
    message: messages.length ? messages.join('\n') : '出品制限があります。',
    approvalUrl: firstLink ? firstLink.resource : null,
  };
}

// SKUの許容形式: 英数字とハイフン・ドット・アンダースコア、1〜40文字(Amazonの一般的なSKU制約に合わせる)。
const SKU_PATTERN = /^[A-Za-z0-9._-]{1,40}$/;

/**
 * POST /api/listings が受理するfulfillmentChannel値。
 * DEFAULT=自己発送(従来通り)、AMAZON_JP=FBA(納品プラン作成は別途セラーセントラルで行う)。
 */
const FULFILLMENT_CHANNELS = ['DEFAULT', 'AMAZON_JP'];

/**
 * POST /api/listings の入力を検証する。
 * @param {object} body リクエストボディ
 * @returns {{ok:true, value:object}|{ok:false, message:string}}
 */
function validateListingInput(body) {
  const asin = String((body && body.asin) || '').trim();
  const sku = String((body && body.sku) || '').trim();
  const conditionType = String((body && body.conditionType) || '').trim();
  const price = body && body.price;
  const quantity = body && body.quantity;
  const conditionNote = String((body && body.conditionNote) || '');
  const fulfillmentChannelRaw = body && body.fulfillmentChannel;
  const fulfillmentChannel =
    fulfillmentChannelRaw === undefined || fulfillmentChannelRaw === null || fulfillmentChannelRaw === ''
      ? 'DEFAULT'
      : String(fulfillmentChannelRaw).trim();

  if (!asin) return { ok: false, message: 'asinは必須です' };
  if (!SKU_PATTERN.test(sku)) return { ok: false, message: 'skuは英数字と-._の1〜40文字で指定してください' };
  if (!LISTING_CONDITION_TYPES.includes(conditionType)) {
    return { ok: false, message: `conditionTypeは ${LISTING_CONDITION_TYPES.join(' / ')} のいずれかを指定してください` };
  }
  if (!Number.isInteger(price) || price <= 0) return { ok: false, message: 'priceは1以上の整数(円)で指定してください' };
  if (!Number.isInteger(quantity) || quantity <= 0) return { ok: false, message: 'quantityは1以上の整数で指定してください' };
  if (!FULFILLMENT_CHANNELS.includes(fulfillmentChannel)) {
    return { ok: false, message: `fulfillmentChannelは ${FULFILLMENT_CHANNELS.join(' / ')} のいずれかを指定してください` };
  }

  return { ok: true, value: { asin, sku, conditionType, price, quantity, conditionNote, fulfillmentChannel } };
}

/**
 * putListingsItemのリクエストボディを組み立てる(spec準拠・PRODUCT/LISTING_OFFER_ONLY固定)。
 * conditionNoteが空のときはcondition_note属性自体を含めない。
 * fulfillmentChannelがAMAZON_JP(FBA)のときはquantityを送らない
 * (FBA在庫は納品数で決まるため。DEFAULT(自己発送)は従来通りquantity付き)。
 * @param {{asin:string, conditionType:string, price:number, quantity:number, conditionNote:string, fulfillmentChannel:string}} input
 * @param {string} marketplaceId
 */
function buildListingItemBody(input, marketplaceId) {
  const fulfillmentAvailability =
    input.fulfillmentChannel === 'AMAZON_JP'
      ? [{ fulfillment_channel_code: 'AMAZON_JP' }]
      : [{ fulfillment_channel_code: 'DEFAULT', quantity: input.quantity }];
  const attributes = {
    merchant_suggested_asin: [{ value: input.asin, marketplace_id: marketplaceId }],
    condition_type: [{ value: input.conditionType, marketplace_id: marketplaceId }],
    purchasable_offer: [
      {
        currency: 'JPY',
        marketplace_id: marketplaceId,
        our_price: [{ schedule: [{ value_with_tax: input.price }] }],
      },
    ],
    fulfillment_availability: fulfillmentAvailability,
  };
  if (input.conditionNote) {
    attributes.condition_note = [
      { language_tag: 'ja_JP', value: input.conditionNote, marketplace_id: marketplaceId },
    ];
  }
  return {
    productType: 'PRODUCT',
    requirements: 'LISTING_OFFER_ONLY',
    attributes,
  };
}

/**
 * リクエストヘッダーからSP-API(LWA)認証情報を解決する。
 * clientId / clientSecret は常にサーバーの .env (LWA_CLIENT_ID / LWA_CLIENT_SECRET) を使用する
 * (ヘッダーは一切見ない。アプリ配布用のOAuthフローに一本化したため)。
 * refreshToken のみ、ヘッダー(X-Spapi-Refresh-Token)を優先し、
 * 無ければ .env (LWA_REFRESH_TOKEN) にフォールバックする(利用者ごとの部分オーバーライド)。
 * いずれか一つでも欠ければnull。
 */
function resolveSpApiCredentials(headers) {
  const clientId = process.env.LWA_CLIENT_ID || null;
  const clientSecret = process.env.LWA_CLIENT_SECRET || null;
  const refreshToken =
    (headers && (headers['x-spapi-refresh-token'] || headers['X-Spapi-Refresh-Token'])) ||
    process.env.LWA_REFRESH_TOKEN ||
    null;

  if (!clientId || !clientSecret || !refreshToken) return null;
  return { clientId, clientSecret, refreshToken };
}

/**
 * 認証情報から、キャッシュキーに混ぜて使うためのハッシュ(先頭8文字)を生成する。
 * 異なるアカウント間でキャッシュ結果が混ざらないようにする目的であり、
 * 機密情報そのものをキーに含めない。
 */
function credentialsHashPrefix(credentials) {
  if (!credentials) return 'noauth';
  const hash = crypto
    .createHash('sha256')
    .update(`${credentials.clientId}:${credentials.refreshToken}`)
    .digest('hex');
  return hash.slice(0, 8);
}

/**
 * SP-APIのsearchCatalogItemsレスポンスから、検索に使ったidentifierに対応する
 * 最初のアイテム(summaries/images/salesRanks込み)を抽出する。
 */
function pickCatalogItem(catalogResponse) {
  const items = catalogResponse && catalogResponse.items;
  if (!items || !items.length) return null;
  return items[0];
}

function extractCatalogFields(item) {
  if (!item) return { asin: null, title: null, imageUrl: null, salesRank: null, listPrice: null };
  const asin = item.asin || null;
  const summary = (item.summaries && item.summaries[0]) || {};
  const title = summary.itemName || null;
  const images = (item.images && item.images[0] && item.images[0].images) || [];
  const imageUrl = images.length ? images[0].link : null;
  const salesRanks = item.salesRanks || [];
  let salesRank = null;
  if (salesRanks.length) {
    const displayRanks = salesRanks[0].displayGroupRanks || salesRanks[0].classificationRanks || [];
    if (displayRanks.length) salesRank = displayRanks[0].rank;
  }
  const listPrice = extractListPriceJpy(item);
  return { asin, title, imageUrl, salesRank, listPrice };
}

// SP-APIのCatalog Items API(2022-04-01)がattributes.list_priceで返す定価は税抜。
// 売値・Keepaの定価(税込)と比較できるよう、消費税10%で税込換算する
// (書籍は軽減税率の対象外のため一律10%でよい)。
const { toTaxIncludedJpy } = require('./taxUtil');

/**
 * カタログitemのattributes.list_price(税抜)から、税込定価(円・整数丸め)を抽出する。
 * attributes.list_price: [{"currency":"JPY","value":1300,"marketplace_id":"..."}] という形式で
 * 書籍カテゴリで返ることを実データで確認済み(旧実装では「実質取得不可」としてnull固定していたが誤り)。
 * 配列が無い/空/valueが数値でない場合はnullを返す。
 */
function extractListPriceJpy(item) {
  const listPriceArr = item && item.attributes && item.attributes.list_price;
  if (!Array.isArray(listPriceArr) || !listPriceArr.length) return null;
  const value = listPriceArr[0] && listPriceArr[0].value;
  return toTaxIncludedJpy(value);
}

/**
 * ポイント推定(Amazonポイント表示は取得APIが別途必要なため、価格の一定割合で概算)。
 * DESIGN.mdのレスポンス例に合わせて cart/new/used 各値に対応するポイントを付与する。
 * 実データ取得ができない場合は概算(価格の約2/3程度、例示値ベース)ではなく、
 * 明確化のためnullを許容しつつ簡易推定(price*0.665程度)を行う。
 * 注: SP-APIには直接的な「ポイント」フィールドが無いため、ここでは
 * ポイント制度の一般的な還元率が取得できないケースに備えnullを返す設計とし、
 * 呼び出し側で価格のみ表示できるようにする。
 */
function estimatePoints() {
  return null;
}

/**
 * Keepa Product本体の手数料情報からbreakEven(手数料控除後の売値)を計算する。
 * referralFeePercent/fbaFees.pickAndPackFeeはProduct本体の属性でoffersパラメータ不要なため、
 * 第1段階(/api/search)・第2段階(/api/offers)のどちらからも同じ引数形式で呼べる。
 * 取得できなければ書籍フォールバック(15%+80円、pricing.fallbackFeesと同一料率)で近似する。
 * @param {object|null} product Keepa Product Object
 * @param {number} landed 送料込み価格
 * @returns {number} breakEven(小数あり得る)
 */
function computeKeepaBreakEven(product, landed) {
  const referralFeePercent =
    product && typeof product.referralFeePercent === 'number' ? product.referralFeePercent : null;
  const fbaPickAndPackFee =
    product && product.fbaFees && typeof product.fbaFees.pickAndPackFee === 'number'
      ? product.fbaFees.pickAndPackFee
      : null;

  if (referralFeePercent != null && fbaPickAndPackFee != null) {
    const referralFee = landed * (referralFeePercent / 100);
    const closingFee = 80; // 書籍カテゴリの成約料(円)
    return Math.round((landed - referralFee - closingFee - fbaPickAndPackFee) * 100) / 100;
  }
  // 書籍フォールバック: 15%手数料 + 成約料80円(pricing.fallbackFeesと同一料率)
  return Math.round((landed - pricing.fallbackFees(landed)) * 100) / 100;
}

async function resolveAsinFromCode(codeType, converted) {
  // isbn/jan は isbn13 または jan を持つのでそれをidentifierとしてCatalog検索
  const identifier = converted.isbn13 || converted.jan;
  if (!identifier) return { identifier: null, asin: null };
  return { identifier, asin: null };
}

/**
 * SP-API経路での/api/search処理(既存ロジック)。source:"spapi"を付与する。
 */
async function handleSearchViaSpApi(req, res, code, credentials, cacheKey) {
  try {
    const converted = convertCode(code);

    if (converted.codeType === CODE_TYPES.UNRESOLVED) {
      const body = {
        codeType: CODE_TYPES.UNRESOLVED,
        asin: null,
        title: null,
        isbn13: null,
        imageUrl: null,
        salesRank: null,
        prices: null,
        profitInputs: null,
        reason: converted.reason || 'unresolved',
        source: 'spapi',
      };
      return res.json(body);
    }

    const { identifier, asin: knownAsin } = await resolveAsinFromCode(converted.codeType, converted);

    let asin = knownAsin;
    let title = null;
    let imageUrl = null;
    let salesRank = null;
    let isbn13 = converted.isbn13 || null;
    let listPrice = null;

    if (!asin) {
      if (!identifier) {
        return res.json({
          codeType: CODE_TYPES.UNRESOLVED,
          asin: null,
          title: null,
          isbn13: null,
          imageUrl: null,
          salesRank: null,
          prices: null,
          profitInputs: null,
          reason: 'no_identifier',
          source: 'spapi',
        });
      }
      const catalogResponse = await pricing.searchCatalogItems(identifier, credentials);
      const item = pickCatalogItem(catalogResponse);
      if (!item) {
        return res.json({
          codeType: CODE_TYPES.UNRESOLVED,
          asin: null,
          title: null,
          isbn13,
          imageUrl: null,
          salesRank: null,
          prices: null,
          profitInputs: null,
          reason: 'catalog_not_found',
          source: 'spapi',
        });
      }
      const fields = extractCatalogFields(item);
      asin = fields.asin;
      title = fields.title;
      imageUrl = fields.imageUrl;
      salesRank = fields.salesRank;
      listPrice = fields.listPrice;
    }

    if (!asin) {
      return res.json({
        codeType: converted.codeType,
        asin: null,
        title,
        isbn13,
        imageUrl,
        salesRank,
        prices: null,
        profitInputs: null,
        reason: 'asin_not_resolved',
        source: 'spapi',
      });
    }

    const [newOffersResp, usedOffersResp] = await Promise.all([
      pricing.getItemOffers(asin, 'New', credentials).catch(() => null),
      pricing.getItemOffers(asin, 'Used', credentials).catch(() => null),
    ]);

    const newSummary = pricing.extractOffersSummary(newOffersResp, 'New');
    const usedSummary = pricing.extractOffersSummary(usedOffersResp, 'Used');

    const cart = newSummary.buyBoxLandedPrice;
    const newPrice = newSummary.lowestLandedPrice;
    const usedPrice = usedSummary.lowestLandedPrice;

    // SP-APIは第1段階でオファーを取得済みのため、第2段階を待たずにオファー一覧も同梱する
    // (アプリはsource=spapi時は/api/offersを呼ばない=2段階ロード廃止)。
    const offers = await buildSpApiOffersPayload(asin, newSummary, usedSummary, credentials);
    const profitInputs = buildProfitInputs(newSummary, usedSummary, offers, listPrice);

    const responseBody = {
      codeType: converted.codeType,
      asin,
      title,
      isbn13,
      imageUrl,
      salesRank,
      prices: {
        cart: cart != null ? cart : null,
        new: newPrice != null ? newPrice : null,
        used: usedPrice != null ? usedPrice : null,
        points: {
          cart: estimatePoints(cart),
          new: estimatePoints(newPrice),
          used: estimatePoints(usedPrice),
        },
      },
      offers,
      profitInputs,
      source: 'spapi',
    };

    searchCache.set(cacheKey, responseBody);
    res.json(responseBody);
  } catch (err) {
    console.error(`[search] code=${code} failed:`, err.message);
    res.status(502).json({ error: 'search_failed', message: err.message });
  }
}

/**
 * Keepa経路での/api/search処理(第1段階・offersなし=1トークン)。source:"keepa"を付与する。
 * SP-API認証情報が無い場合のフォールバック(KEEPA_API_KEYが必要)。
 */
async function handleSearchViaKeepa(req, res, code, cacheKey) {
  try {
    const converted = convertCode(code);

    if (converted.codeType === CODE_TYPES.UNRESOLVED) {
      return res.json({
        codeType: CODE_TYPES.UNRESOLVED,
        asin: null,
        title: null,
        isbn13: null,
        imageUrl: null,
        salesRank: null,
        prices: null,
        profitInputs: null,
        reason: converted.reason || 'unresolved',
        source: 'keepa',
      });
    }

    const isbn13 = converted.isbn13 || null;
    const janOrIsbn = converted.isbn13 || converted.jan;

    if (!janOrIsbn) {
      return res.json({
        codeType: CODE_TYPES.UNRESOLVED,
        asin: null,
        title: null,
        isbn13,
        imageUrl: null,
        salesRank: null,
        prices: null,
        profitInputs: null,
        reason: 'no_identifier',
        source: 'keepa',
      });
    }

    const { product } = await keepa.getProduct({ code: janOrIsbn });
    const mapped = keepa.mapProductToSearchResult(product);

    if (!mapped) {
      return res.json({
        codeType: converted.codeType,
        asin: null,
        title: null,
        isbn13,
        imageUrl: null,
        salesRank: null,
        prices: null,
        profitInputs: null,
        reason: 'catalog_not_found',
        source: 'keepa',
      });
    }

    // breakEvenはstats最安値(送料不明のためlandedとみなす。第2段階statsフォールバックと同じ扱い)。
    const profitInputs = {
      listPrice: mapped.listPrice,
      sellerCounts: mapped.sellerCounts,
      breakEven: {
        new: mapped.prices.new != null ? computeKeepaBreakEven(product, mapped.prices.new) : null,
        used: mapped.prices.used != null ? computeKeepaBreakEven(product, mapped.prices.used) : null,
      },
    };

    const responseBody = {
      codeType: converted.codeType,
      asin: mapped.asin,
      title: mapped.title,
      isbn13,
      imageUrl: mapped.imageUrl,
      salesRank: mapped.salesRank,
      prices: mapped.prices,
      profitInputs,
      source: 'keepa',
    };

    // Keepa結果は長め(30分)にキャッシュしトークン消費を抑える(共有コスト削減)。
    searchCache.set(cacheKey, responseBody, KEEPA_CACHE_TTL_MS);
    res.json(responseBody);
  } catch (err) {
    if (err.code === 'keepa_tokens_exhausted') {
      return res.status(503).json({ error: 'keepa_tokens_exhausted', message: err.message });
    }
    console.error(`[search:keepa] code=${code} failed:`, err.message);
    res.status(502).json({ error: 'search_failed', message: err.message });
  }
}

// GET /api/search?code=
router.get('/api/search', async (req, res) => {
  const code = String(req.query.code || '').trim();
  if (!code) {
    return res.status(400).json({ error: 'code query parameter is required' });
  }

  // 無料プランのデバイス単位・日次バックストップ(クライアント改ざん対策)。Proは無制限。
  if (!isProRequest(req.headers)) {
    const deviceId = req.headers['x-device-id'] || req.headers['X-Device-Id'];
    const check = deviceRateLimit.registerAndCheck(
      deviceId ? String(deviceId) : null,
      FREE_DEVICE_DAILY_LIMIT
    );
    if (!check.allowed) {
      return res.status(429).json({
        error: 'daily_limit_exceeded',
        message: '本日の無料検索の上限に達しました。Proにアップグレードすると無制限に使えます。',
      });
    }
  }

  const credentials = resolveSpApiCredentials(req.headers);

  if (credentials) {
    // キャッシュキーにプランを含める(spapi:<hash>:<plan>:<code>)。
    // プラン非依存だと無料での検索結果が、30分以内のPro再検索に誤って返ってしまうため。
    const plan = isProRequest(req.headers) ? 'pro' : 'free';
    const cacheKey = `spapi:${credentialsHashPrefix(credentials)}:${plan}:${code}`;
    const cached = searchCache.get(cacheKey);
    if (cached) return res.json(cached);
    return handleSearchViaSpApi(req, res, code, credentials, cacheKey);
  }

  if (keepa.getApiKey()) {
    const cacheKey = `keepa:${code}`;
    const cached = searchCache.get(cacheKey);
    if (cached) return res.json(cached);
    return handleSearchViaKeepa(req, res, code, cacheKey);
  }

  return res.status(503).json({ error: 'spapi_credentials_missing', message: SPAPI_CREDENTIALS_MISSING_MESSAGE });
});

/**
 * SP-APIのSubCondition文字列を統一契約のcondition文字列に変換する。
 * SP-APIのSubConditionは実運用上ケースの揺れが確認されている
 * (GitHub Issue amzn/selling-partner-api-models#2902: ドキュメント上の表記と実際のレスポンスの大文字/小文字が異なる)ため、
 * 小文字化・区切り除去して緩く一致させる。
 * 値の一覧(MWS/SP-API文書由来): New, Mint, VeryGood/Very Good, Good, Acceptable, Poor, Club, Refurbished, OEM, Warranty, Open Box, Other
 */
function subConditionToString(subCondition) {
  if (!subCondition) return 'acceptable';
  const normalized = String(subCondition).toLowerCase().replace(/[\s_-]/g, '');
  if (normalized === 'new') return 'new';
  if (normalized === 'mint' || normalized === 'likenew') return 'like_new';
  if (normalized === 'verygood') return 'very_good';
  if (normalized === 'good') return 'good';
  if (normalized === 'acceptable') return 'acceptable';
  // poor/club/refurbished/openbox/oem/warranty/other等は契約外のため中古下位(acceptable)にフォールバック
  return 'acceptable';
}

/**
 * spapi: 取得済みのnew/used summaryから /api/offers 契約のオファー本体を組み立てる。
 * (手数料バッチ見積り + breakEven算出)。第1段階完結(handleSearchViaSpApi)と
 * /api/offersエンドポイント(buildOffersResponseViaSpApi)の両方から使う共通ヘルパー。
 * @returns {{referencePrice: number|null, newCount: number, usedCount: number, new: object[], used: object[]}}
 */
async function buildSpApiOffersPayload(asin, newSummary, usedSummary, credentials) {
  const allOffers = [
    ...newSummary.offers.map((o) => ({ ...o, _bucket: 'new' })),
    ...usedSummary.offers.map((o) => ({ ...o, _bucket: 'used' })),
  ];

  // 手数料バッチ見積り(各オファー価格ごと)
  let feesResp = null;
  if (allOffers.length) {
    try {
      feesResp = await pricing.getMyFeesEstimatesBatch(
        allOffers.map((o) => ({ asin, price: o.landed, identifier: asin })),
        credentials
      );
    } catch (err) {
      feesResp = null; // フォールバック計算へ
    }
  }

  // getMyFeesEstimatesの200応答はトップレベルが素の配列(各要素がFeesEstimateResult)。
  // payloadで包まれる形は旧実装が想定していた誤りだが、防御的に両対応を残す。
  const feesList = Array.isArray(feesResp) ? feesResp : (feesResp && feesResp.payload) || [];

  function feeForIndex(index, landed) {
    const entry = feesList[index];
    const feesEstimate =
      (entry &&
        entry.FeesEstimateResult &&
        entry.FeesEstimateResult.FeesEstimate &&
        entry.FeesEstimateResult.FeesEstimate.TotalFeesEstimate) ||
      (entry && entry.FeesEstimate && entry.FeesEstimate.TotalFeesEstimate);
    if (feesEstimate && typeof feesEstimate.Amount === 'number') {
      return feesEstimate.Amount;
    }
    return pricing.fallbackFees(landed);
  }

  function toOfferDto(o, index) {
    const totalFees = feeForIndex(index, o.landed);
    const breakEven = Math.round((o.landed - totalFees) * 100) / 100;
    return {
      price: o.price,
      shipping: o.shipping,
      landed: o.landed,
      condition: o._bucket === 'new' ? 'new' : subConditionToString(o.condition),
      isBuyBox: o.isBuyBox,
      // Amazon本体の在庫か(アプリで「新品(Ama)」と表示して区別する)。
      isAmazon: o.sellerId === AMAZON_JP_SELLER_ID,
      breakEven,
    };
  }

  const newDtos = [];
  const usedDtos = [];
  allOffers.forEach((o, index) => {
    const dto = toOfferDto(o, index);
    if (o._bucket === 'new') newDtos.push(dto);
    else usedDtos.push(dto);
  });

  return {
    // 取得元。/api/searchへ同梱される場合もアプリが経路を判別できるよう必ず付ける
    // (送料0を「送無料」と表示してよいのはSP-API経路のみのため)。
    source: 'spapi',
    referencePrice: newSummary.buyBoxLandedPrice || newSummary.lowestLandedPrice || null,
    newCount: newDtos.length,
    usedCount: usedDtos.length,
    new: newDtos,
    used: usedDtos,
  };
}

/**
 * offersPayload(new/used各配列、要素にlanded/breakEven)からlanded最安のオファーのbreakEvenを取り出す。
 * オファー0件はnull。
 */
function pickCheapestBreakEven(dtos) {
  if (!dtos || !dtos.length) return null;
  const cheapest = dtos.reduce((min, o) => (o.landed < min.landed ? o : min), dtos[0]);
  return cheapest.breakEven;
}

/**
 * spapi経路: /api/search の profitInputs を組み立てる。
 * listPriceはCatalog Items APIのattributes.list_price(税抜)を税込換算した値
 * (extractListPriceJpy)。取得できない商品はnull。sellerCountsはSummary.TotalOfferCount、
 * breakEvenは既に組み立て済みのoffersPayload(buildSpApiOffersPayload)を再利用し、
 * 手数料計算を二重実装しない(landed最安のオファーのbreakEvenを採用)。
 */
function buildProfitInputs(newSummary, usedSummary, offersPayload, listPrice) {
  return {
    listPrice: listPrice != null ? listPrice : null,
    sellerCounts: {
      new: newSummary.totalOfferCount,
      used: usedSummary.totalOfferCount,
    },
    breakEven: {
      new: pickCheapestBreakEven(offersPayload.new),
      used: pickCheapestBreakEven(offersPayload.used),
    },
  };
}

/**
 * spapi経路: /api/offersエンドポイント用。getItemOffersを取得して共通ヘルパーで組み立てる。
 */
async function buildOffersResponseViaSpApi(asin, credentials) {
  const [newOffersResp, usedOffersResp] = await Promise.all([
    pricing.getItemOffers(asin, 'New', credentials).catch(() => null),
    pricing.getItemOffers(asin, 'Used', credentials).catch(() => null),
  ]);
  const newSummary = pricing.extractOffersSummary(newOffersResp, 'New');
  const usedSummary = pricing.extractOffersSummary(usedOffersResp, 'Used');
  const payload = await buildSpApiOffersPayload(asin, newSummary, usedSummary, credentials);
  return { source: 'spapi', ...payload };
}

/**
 * keepa経路: getProduct(offers=20)結果を /api/offers 統一契約にマッピングする。
 * breakEvenはKeepaの手数料情報(referralFeePercent/fbaFees.pickAndPackFee)が取得できればそれを使い、
 * 取得できなければ書籍フォールバック(15%+80円、pricing.fallbackFeesと同じ料率)で近似する。
 */
async function buildOffersResponseViaKeepa(asin) {
  const { product } = await keepa.getProduct({ asin, offers: 20 });
  const { newOffers, usedOffers, referencePrice } = keepa.extractOffersFromProduct(product);

  function toDto(o) {
    return {
      price: o.price,
      shipping: o.shipping,
      landed: o.landed,
      condition: o.condition,
      isBuyBox: o.isBuyBox,
      breakEven: computeKeepaBreakEven(product, o.landed),
    };
  }

  // 価格(landed)の安い順に並べる(パネル表示を最安値から見せる)。
  const byLandedAsc = (a, b) => (a.landed ?? Infinity) - (b.landed ?? Infinity);
  const newDtos = newOffers.map(toDto).sort(byLandedAsc);
  const usedDtos = usedOffers.map(toDto).sort(byLandedAsc);

  // フォールバック: Keepaが個別オファーを返さない、または鮮度フィルタで全除外された場合でも、
  // stats.current の新品/中古最安値でパネルに価格を表示する(価格が全く出ない事態を防ぐ)。
  const current = (product && product.stats && product.stats.current) || [];
  const statsNew = keepa.normalizePrice(current[keepa.CSV_TYPE.NEW]);
  const statsUsed = keepa.normalizePrice(current[keepa.CSV_TYPE.USED]);
  function statsOffer(price, condition) {
    return {
      price,
      shipping: 0,
      landed: price,
      condition,
      isBuyBox: false,
      breakEven: computeKeepaBreakEven(product, price),
    };
  }
  const finalNew = newDtos.length ? newDtos : statsNew != null ? [statsOffer(statsNew, 'new')] : [];
  const finalUsed = usedDtos.length ? usedDtos : statsUsed != null ? [statsOffer(statsUsed, 'used')] : [];

  return {
    source: 'keepa',
    referencePrice: referencePrice != null ? referencePrice : null,
    newCount: finalNew.length,
    usedCount: finalUsed.length,
    new: finalNew,
    used: finalUsed,
  };
}

// GET /api/offers?asin=&source=spapi|keepa
router.get('/api/offers', async (req, res) => {
  const asin = String(req.query.asin || '').trim();
  if (!asin) {
    return res.status(400).json({ error: 'asin query parameter is required' });
  }

  const source = String(req.query.source || 'spapi').trim().toLowerCase();

  // 無料プランはKeepa経路のオファー(第2段階=getProductのトークン消費が大きい)を制限する。
  // SP-API経路のオファーは第1段階(/api/search)に同梱済みで、BYO(利用者自身の枠)のため制限しない。
  if (!isProRequest(req.headers) && source === 'keepa') {
    return res.status(403).json({ error: 'plan_required', message: PLAN_REQUIRED_MESSAGE });
  }

  if (source === 'keepa') {
    if (!keepa.getApiKey()) {
      return res.status(503).json({ error: 'spapi_credentials_missing', message: SPAPI_CREDENTIALS_MISSING_MESSAGE });
    }

    const cacheKey = `keepa:${asin}`;
    const cached = offersCache.get(cacheKey);
    if (cached) return res.json(cached);

    try {
      const responseBody = await buildOffersResponseViaKeepa(asin);
      // Keepa結果は長め(30分)にキャッシュしトークン消費を抑える(共有コスト削減)。
      offersCache.set(cacheKey, responseBody, KEEPA_CACHE_TTL_MS);
      res.json(responseBody);
    } catch (err) {
      if (err.code === 'keepa_tokens_exhausted') {
        return res.status(503).json({ error: 'keepa_tokens_exhausted', message: err.message });
      }
      console.error(`[offers:keepa] asin=${asin} failed:`, err.message);
      res.status(502).json({ error: 'offers_failed', message: err.message });
    }
    return;
  }

  // デフォルト: spapi経路
  const credentials = resolveSpApiCredentials(req.headers);
  if (!credentials) {
    return res.status(503).json({ error: 'spapi_credentials_missing', message: SPAPI_CREDENTIALS_MISSING_MESSAGE });
  }

  const cacheKey = `spapi:${credentialsHashPrefix(credentials)}:${asin}`;

  const cached = offersCache.get(cacheKey);
  if (cached) {
    return res.json(cached);
  }

  try {
    const responseBody = await buildOffersResponseViaSpApi(asin, credentials);
    offersCache.set(cacheKey, responseBody);
    res.json(responseBody);
  } catch (err) {
    console.error(`[offers] asin=${asin} failed:`, err.message);
    res.status(502).json({ error: 'offers_failed', message: err.message });
  }
});

// range クエリの許可値(CHANGES-v6.1.md)。それ以外・未指定は90扱い。
const ALLOWED_GRAPH_RANGES = [90, 365, 1095];

/**
 * range クエリパラメータを検証し、許可値(90/365/1095)のいずれかに正規化する。
 * 不正値・未指定は90を返す。
 * @param {*} rawRange req.query.range
 * @returns {number}
 */
function normalizeGraphRange(rawRange) {
  const parsed = parseInt(rawRange, 10);
  if (ALLOWED_GRAPH_RANGES.includes(parsed)) return parsed;
  return 90;
}

// GET /api/graph?asin=&range= — Keepaグラフ画像プロキシ(APIキーをアプリに晒さないため必須)
router.get('/api/graph', async (req, res) => {
  const asin = String(req.query.asin || '').trim();
  if (!asin) {
    return res.status(400).json({ error: 'asin query parameter is required' });
  }

  // グラフはKeepa鍵消費(サーバー共有コスト)のためPro限定。
  if (!isProRequest(req.headers)) {
    return res.status(403).json({ error: 'plan_required', message: 'グラフはProプランでご利用いただけます。' });
  }

  if (!keepa.getApiKey()) {
    return res.status(404).json({ error: 'keepa_not_configured' });
  }

  const range = normalizeGraphRange(req.query.range);

  const cacheKey = `graph:${asin}:${range}`;
  const cached = graphCache.get(cacheKey);
  if (cached) {
    return res.binary(cached.buffer, cached.contentType);
  }

  try {
    const { buffer, contentType } = await keepa.getGraphImage(asin, range);
    graphCache.set(cacheKey, { buffer, contentType });
    res.binary(buffer, contentType);
  } catch (err) {
    if (err.code === 'keepa_tokens_exhausted') {
      return res.status(503).json({ error: 'keepa_tokens_exhausted', message: err.message });
    }
    console.error(`[graph] asin=${asin} failed:`, err.message);
    res.status(502).json({ error: 'graph_failed', message: err.message });
  }
});

/**
 * FeeDetailListの1件(FeeType)を、アプリ向けのtype/labelに分類する。
 * ReferralFee→販売手数料 / VariableClosingFee・FixedClosingFee→カテゴリ成約料 /
 * FBAFees・FBAPerUnitFulfillmentFee等FBA系(FeeTypeが"FBA"始まり)→FBA手数料。
 * 未知のFeeTypeは金額を落とさずother(labelはFeeType文字列そのまま)として扱う。
 */
function mapFeeDetailType(feeType) {
  if (feeType === 'ReferralFee') return { type: 'referral', label: '販売手数料' };
  if (feeType === 'VariableClosingFee' || feeType === 'FixedClosingFee') {
    return { type: 'closing', label: 'カテゴリ成約料' };
  }
  if (typeof feeType === 'string' && feeType.startsWith('FBA')) {
    return { type: 'fba', label: 'FBA手数料' };
  }
  return { type: 'other', label: feeType || '手数料' };
}

/**
 * getMyFeesEstimatesBatch(1件)の応答からFeesEstimate本体を取り出す。
 * 本番実機で確認済みの応答形はトップレベルが素の配列(各要素がFeesEstimateResult)。
 * payloadで包まれる形などは構造揺れに備えた防御的フォールバック。
 */
function extractFeesEstimate(feesResp) {
  const payload = feesResp && feesResp.payload;
  const list = Array.isArray(feesResp)
    ? feesResp
    : Array.isArray(payload)
    ? payload
    : payload && Array.isArray(payload.FeesEstimateResultList)
    ? payload.FeesEstimateResultList
    : null;
  const entry = list ? list[0] : payload;
  if (!entry) return null;
  return (entry.FeesEstimateResult && entry.FeesEstimateResult.FeesEstimate) || entry.FeesEstimate || null;
}

/**
 * FeeDetailListから /api/fees-estimate のレスポンス(total/breakdown)を組み立てる。
 * 消費税: 各FeeDetailのTaxAmountの合計。全て0/欠落の場合は手数料小計の10%(Math.round)を
 * 概算として計上する(実応答でのTaxAmountの返り方は本番デプロイ前に実データで要確認)。
 * totalはbreakdown各行の合計値(SP-APIのTotalFeesEstimateはそのまま使わない。
 * 消費税を概算計上した場合でも整合させるため)。
 */
function buildFeesBreakdown(feeDetailList) {
  const rows = new Map();
  let feeSubtotal = 0;
  let taxSum = 0;
  let hasNonZeroTax = false;

  for (const detail of feeDetailList || []) {
    if (!detail) continue;
    const { type, label } = mapFeeDetailType(detail.FeeType);
    const amount =
      detail.FeeAmount && typeof detail.FeeAmount.Amount === 'number'
        ? detail.FeeAmount.Amount
        : detail.FinalFee && typeof detail.FinalFee.Amount === 'number'
        ? detail.FinalFee.Amount
        : 0;
    feeSubtotal += amount;

    const key = `${type}:${label}`;
    if (rows.has(key)) {
      rows.get(key).amount += amount;
    } else {
      rows.set(key, { type, label, amount });
    }

    const taxAmount =
      detail.TaxAmount && typeof detail.TaxAmount.Amount === 'number' ? detail.TaxAmount.Amount : 0;
    if (taxAmount !== 0) hasNonZeroTax = true;
    taxSum += taxAmount;
  }

  const breakdown = Array.from(rows.values()).map((row) => ({ ...row, amount: Math.round(row.amount) }));
  const taxAmount = hasNonZeroTax ? Math.round(taxSum) : Math.round(feeSubtotal * 0.1);
  breakdown.push({ type: 'tax', label: '消費税', amount: taxAmount });

  const total = breakdown.reduce((sum, row) => sum + row.amount, 0);
  return { total, breakdown };
}

// price クエリ(円)を検証する。正の整数文字列のみ許可(小数・負数・非数値は不正)。
function parsePositiveIntQuery(raw) {
  if (raw === undefined || raw === null) return null;
  const str = String(raw).trim();
  if (!/^\d+$/.test(str)) return null;
  const n = parseInt(str, 10);
  return n > 0 ? n : null;
}

// GET /api/fees-estimate?asin=&price=&fba=1|0 — 手数料見積り(Pro+BYOトークン必須)
//
// 入力バリデーションを先に行い、その後にゲートを通す(/api/listings/restrictionsと同じ理由:
// サーバー側のLWA_CLIENT_ID/LWA_CLIENT_SECRET未設定時に400を503化させないため)。
// 手数料はSKU非依存・出品内容を含まないためDPP上の懸念はないが、方針としてasin等はログに出さない。
router.get('/api/fees-estimate', async (req, res) => {
  const asin = String(req.query.asin || '').trim();
  if (!asin) {
    return res.status(400).json({ error: 'invalid_request', message: 'asinは必須です' });
  }
  const price = parsePositiveIntQuery(req.query.price);
  if (price == null) {
    return res.status(400).json({ error: 'invalid_request', message: 'priceは1以上の整数(円)で指定してください' });
  }
  const fbaRaw = req.query.fba === undefined || req.query.fba === null || req.query.fba === '' ? '0' : String(req.query.fba);
  if (fbaRaw !== '0' && fbaRaw !== '1') {
    return res.status(400).json({ error: 'invalid_request', message: 'fbaは1または0で指定してください' });
  }
  const fba = fbaRaw === '1';

  const credentials = requireProByoCredentials(req, res);
  if (!credentials) return;

  try {
    const feesResp = await pricing.getMyFeesEstimatesBatch(
      [{ asin, price, identifier: asin, isAmazonFulfilled: fba }],
      credentials
    );
    const feesEstimate = extractFeesEstimate(feesResp);
    const feeDetailList = (feesEstimate && feesEstimate.FeeDetailList) || [];
    const { total, breakdown } = buildFeesBreakdown(feeDetailList);
    res.json({ total, breakdown });
  } catch (err) {
    console.error('[fees-estimate] failed:', err.message);
    res.status(502).json({ error: 'fees_estimate_failed', message: err.message });
  }
});

// GET /api/listings/restrictions?asin=&condition= — 出品制限の事前チェック(Pro+BYOトークン必須)
//
// 入力バリデーション(asin/condition)を先に行い、その後にPro+BYOトークンのゲートを通す。
// 逆順(ゲート→入力検証)にすると、サーバー側のLWA_CLIENT_ID/LWA_CLIENT_SECRET未設定時に
// 400で返すべき不正入力が503(spapi_credentials_missing)に化けてしまう
// (resolveSpApiCredentialsがclientId/clientSecret欠落でnullを返すため)。
router.get('/api/listings/restrictions', async (req, res) => {
  const asin = String(req.query.asin || '').trim();
  if (!asin) {
    return res.status(400).json({ error: 'asin query parameter is required' });
  }
  const condition = String(req.query.condition || '').trim();
  if (!LISTING_CONDITION_TYPES.includes(condition)) {
    return res.status(400).json({ error: 'invalid_condition', message: `conditionは ${LISTING_CONDITION_TYPES.join(' / ')} のいずれかを指定してください` });
  }

  const credentials = requireProByoCredentials(req, res);
  if (!credentials) return;

  try {
    const response = await listings.getListingsRestrictions({
      asin,
      sellerId: credentials.sellerId,
      conditionType: condition,
      credentials,
    });
    res.json(summarizeRestrictions(response));
  } catch (err) {
    console.error(`[listings:restrictions] asin=${asin} failed:`, err.message);
    res.status(502).json({ error: 'restrictions_failed', message: err.message });
  }
});

// POST /api/listings — オファー出品(putListingsItem)。Pro+BYOトークン必須。
// トークン・出品内容はサーバーに保存しない(DPP整合)。応答のstatus/issuesはそのまま透過する。
router.post('/api/listings', async (req, res) => {
  const credentials = requireProByoCredentials(req, res);
  if (!credentials) return;

  const validated = validateListingInput(req.body);
  if (!validated.ok) {
    return res.status(400).json({ error: 'invalid_request', message: validated.message });
  }
  const input = validated.value;

  try {
    const body = buildListingItemBody(input, spapiClient.getMarketplaceId());
    const response = await listings.putListingsItem({
      sellerId: credentials.sellerId,
      sku: input.sku,
      body,
      credentials,
    });
    res.json({
      status: (response && response.status) || null,
      submissionId: (response && response.submissionId) || null,
      issues: (response && response.issues) || [],
    });
  } catch (err) {
    console.error(`[listings:put] asin=${input.asin} failed:`, err.message);
    res.status(502).json({ error: 'listing_failed', message: err.message });
  }
});

// GET /api/spapi/test
// ヘッダー(なければ.env)の認証情報でLWAトークン取得を1回試行し、疎通確認する。
// SP-API本体(Catalog/Pricing等)は呼ばない。トークン取得成功=連携成功とみなす。
router.get('/api/spapi/test', async (req, res) => {
  const credentials = resolveSpApiCredentials(req.headers);
  if (!credentials) {
    return res.json({ ok: false, message: SPAPI_CREDENTIALS_MISSING_MESSAGE });
  }

  try {
    await spapiAuth.getAccessToken(credentials);
    return res.json({ ok: true });
  } catch (err) {
    return res.json({ ok: false, message: err.message });
  }
});

router.get('/oauth/login', oauth.handleOAuthLogin);
router.get('/oauth/callback', oauth.handleOAuthCallback);

router.searchCache = searchCache;
router.offersCache = offersCache;
router.graphCache = graphCache;
// テスト用途にプラン判定関数を公開する。
router.isProRequest = isProRequest;
// テスト用途に定価抽出ヘルパーを公開する。
router.extractListPriceJpy = extractListPriceJpy;
// テスト用途に出品系ヘルパーを公開する。
router.summarizeRestrictions = summarizeRestrictions;
router.LISTING_CONDITION_TYPES = LISTING_CONDITION_TYPES;
router.validateListingInput = validateListingInput;
router.buildListingItemBody = buildListingItemBody;
router.FULFILLMENT_CHANNELS = FULFILLMENT_CHANNELS;
router.mapFeeDetailType = mapFeeDetailType;
router.buildFeesBreakdown = buildFeesBreakdown;

module.exports = router;
