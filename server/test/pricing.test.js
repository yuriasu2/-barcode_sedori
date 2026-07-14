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
