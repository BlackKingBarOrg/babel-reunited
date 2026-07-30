# frozen_string_literal: true

RSpec.describe BabelReunited::UsageFuse do
  fab!(:user)

  before do
    enable_current_plugin
    Discourse.redis.flushdb
  end

  describe ".record! and counters" do
    it "increments site and user counters together" do
      described_class.record!(user)
      described_class.record!(user)

      expect(described_class.site_count).to eq(2)
      expect(described_class.user_count(user)).to eq(2)
    end
  end

  describe ".site_exhausted?" do
    it "returns false below the limit" do
      SiteSetting.babel_reunited_daily_translation_limit = 2
      described_class.record!(user)
      expect(described_class.site_exhausted?).to be false
    end

    it "returns true at the limit" do
      SiteSetting.babel_reunited_daily_translation_limit = 2
      2.times { described_class.record!(user) }
      expect(described_class.site_exhausted?).to be true
    end

    it "is disabled when the limit is 0" do
      SiteSetting.babel_reunited_daily_translation_limit = 0
      10.times { described_class.record!(user) }
      expect(described_class.site_exhausted?).to be false
    end
  end

  describe ".user_exhausted?" do
    it "tracks per-user counts independently" do
      SiteSetting.babel_reunited_user_daily_translation_limit = 1
      other_user = Fabricate(:user)

      described_class.record!(user)

      expect(described_class.user_exhausted?(user)).to be true
      expect(described_class.user_exhausted?(other_user)).to be false
    end

    it "is disabled when the limit is 0" do
      SiteSetting.babel_reunited_user_daily_translation_limit = 0
      5.times { described_class.record!(user) }
      expect(described_class.user_exhausted?(user)).to be false
    end
  end
end
