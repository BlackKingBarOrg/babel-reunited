# frozen_string_literal: true

RSpec.describe BabelReunited::RateLimiter do
  before do
    enable_current_plugin
    SiteSetting.babel_reunited_rate_limit_per_minute = 5
    Discourse.redis.flushdb
  end

  describe ".can_make_request?" do
    it "returns true when under limit" do
      expect(described_class.can_make_request?).to be true
    end

    it "returns false when at limit" do
      5.times { described_class.record_request }
      expect(described_class.can_make_request?).to be false
    end

    it "returns false when over limit" do
      6.times { described_class.record_request }
      expect(described_class.can_make_request?).to be false
    end
  end

  describe ".record_request" do
    it "increments the counter" do
      expect { described_class.record_request }.to change { described_class.remaining_requests }.by(
        -1,
      )
    end
  end

  describe ".remaining_requests" do
    it "returns full limit when no requests made" do
      expect(described_class.remaining_requests).to eq(5)
    end

    it "returns correct remaining count" do
      3.times { described_class.record_request }
      expect(described_class.remaining_requests).to eq(2)
    end

    it "returns 0 when limit is reached" do
      5.times { described_class.record_request }
      expect(described_class.remaining_requests).to eq(0)
    end

    it "does not go below 0" do
      10.times { described_class.record_request }
      expect(described_class.remaining_requests).to eq(0)
    end
  end
end
