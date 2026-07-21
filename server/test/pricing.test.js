'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const pricing = require('../src/spapi/pricing');

test('extractOffersSummary: condition指定時はLowestPricesを該当条件で絞る(新品要求で中古最安を拾わない)', () => {
  const resp = {
    payload: {
      Summary: {
        LowestPrices: [
          { condition: 'new', LandedPrice: { Amount: 2000 } },
          { condition: 'used', LandedPrice: { Amount: 1200 } },
        ],
        BuyBoxPrices: [],
      },
      Offers: [],
    },
  };
  assert.equal(pricing.extractOffersSummary(resp, 'New').lowestLandedPrice, 2000);
  assert.equal(pricing.extractOffersSummary(resp, 'Used').lowestLandedPrice, 1200);
});

test('extractOffersSummary: 該当条件がLowestPricesに無ければオファー最安landedで代替', () => {
  const resp = {
    payload: {
      Summary: {
        LowestPrices: [{ condition: 'used', LandedPrice: { Amount: 1200 } }],
        BuyBoxPrices: [],
      },
      Offers: [
        { ListingPrice: { Amount: 1800 }, Shipping: { Amount: 300 }, SubCondition: 'New' },
      ],
    },
  };
  // New要求だがLowestPricesにnew無し → Offers(1800+300=2100)で代替
  assert.equal(pricing.extractOffersSummary(resp, 'New').lowestLandedPrice, 2100);
});

test('extractOffersSummary: condition未指定は全LowestPricesの最小(従来動作)', () => {
  const resp = {
    payload: {
      Summary: {
        LowestPrices: [
          { condition: 'new', LandedPrice: { Amount: 2000 } },
          { condition: 'used', LandedPrice: { Amount: 1200 } },
        ],
        BuyBoxPrices: [],
      },
      Offers: [],
    },
  };
  assert.equal(pricing.extractOffersSummary(resp).lowestLandedPrice, 1200);
});

test('extractOffersSummary: totalOfferCountはSummary.TotalOfferCountをそのまま返す', () => {
  const resp = {
    payload: {
      Summary: { TotalOfferCount: 7, LowestPrices: [], BuyBoxPrices: [] },
      Offers: [],
    },
  };
  assert.equal(pricing.extractOffersSummary(resp).totalOfferCount, 7);
});

test('extractOffersSummary: totalOfferCountはSummaryに無ければOffers件数で代替する', () => {
  const resp = {
    payload: {
      Summary: { LowestPrices: [], BuyBoxPrices: [] },
      Offers: [
        { ListingPrice: { Amount: 1000 }, Shipping: { Amount: 0 } },
        { ListingPrice: { Amount: 1200 }, Shipping: { Amount: 0 } },
      ],
    },
  };
  assert.equal(pricing.extractOffersSummary(resp).totalOfferCount, 2);
});

test('extractOffersSummary: payloadが無ければtotalOfferCountはnull', () => {
  assert.equal(pricing.extractOffersSummary(null).totalOfferCount, null);
  assert.equal(pricing.extractOffersSummary({}).totalOfferCount, null);
});

test('extractOffersSummary: 小数円のオファーはprice/shipping/landedすべて整数に丸められる(iOS Offer.price等がIntのためデコード失敗を防ぐ)', () => {
  const resp = {
    payload: {
      Summary: { LowestPrices: [], BuyBoxPrices: [] },
      Offers: [
        { ListingPrice: { Amount: 1149.5 }, Shipping: { Amount: 440 }, SubCondition: 'New' },
      ],
    },
  };
  const { offers } = pricing.extractOffersSummary(resp, 'New');
  assert.equal(offers.length, 1);
  assert.equal(Number.isInteger(offers[0].price), true);
  assert.equal(Number.isInteger(offers[0].shipping), true);
  assert.equal(Number.isInteger(offers[0].landed), true);
  assert.equal(offers[0].price, 1150); // Math.round(1149.5) = 1150
  assert.equal(offers[0].shipping, 440);
  assert.equal(offers[0].landed, 1590); // 1150 + 440
});

test('extractOffersSummary: 実データ再現(ISBN 9784651206035で確認された小数円 1149.5)がデコード可能な整数になる', () => {
  // 本番サーバーから実際に取得した再現データの一部(ListingPrice.Amount: 1149.5, Shipping.Amount: 440)。
  // 修正前はこのオファーがiOSのOffer(price: Int?)デコードに失敗し「応答の解析に失敗しました」エラーになっていた。
  const resp = {
    payload: {
      Summary: {
        LowestPrices: [{ condition: 'new', LandedPrice: { Amount: 1149.5 } }],
        BuyBoxPrices: [{ condition: 'new', LandedPrice: { Amount: 1149.5 } }],
      },
      Offers: [
        { ListingPrice: { Amount: 1149.5 }, Shipping: { Amount: 440 }, SubCondition: 'New', SellerId: 'A_EXAMPLE' },
      ],
    },
  };
  const result = pricing.extractOffersSummary(resp, 'New');
  assert.equal(Number.isInteger(result.offers[0].price), true);
  assert.equal(result.offers[0].price, 1150);
  assert.equal(Number.isInteger(result.lowestLandedPrice), true);
  assert.equal(result.lowestLandedPrice, 1150); // Math.round(1149.5) = 1150
  assert.equal(Number.isInteger(result.buyBoxLandedPrice), true);
  assert.equal(result.buyBoxLandedPrice, 1150);
});
