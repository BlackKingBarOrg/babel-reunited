# frozen_string_literal: true

RSpec.describe BabelReunited::RateLimiter do
  before do
    enable_current_plugin
    SiteSetting.babel_reunited_rate_limit_per_minute = 5
    Discourse.redis.flushdb
  end

  describe ".perform_request_if_allowed" do
    it "returns true when under limit" do
      expect(described_class.perform_request_if_allowed).to be true
    end

    it "returns true and decrements remaining on each call" do
      expect { described_class.perform_request_if_allowed }.to change {
        described_class.remaining_requests
      }.by(-1)
    end

    it "returns false when at limit" do
      5.times { described_class.perform_request_if_allowed }
      expect(described_class.perform_request_if_allowed).to be false
    end

    it "does not increment counter when over limit" do
      5.times { described_class.perform_request_if_allowed }
      described_class.perform_request_if_allowed
      expect(described_class.remaining_requests).to eq(0)
    end
  end

  describe ".remaining_requests" do
    it "returns full limit when no requests made" do
      expect(described_class.remaining_requests).to eq(5)
    end

    it "returns correct remaining count" do
      3.times { described_class.perform_request_if_allowed }
      expect(described_class.remaining_requests).to eq(2)
    end

    it "returns 0 when limit is reached" do
      5.times { described_class.perform_request_if_allowed }
      expect(described_class.remaining_requests).to eq(0)
    end
  end
end
