# frozen_string_literal: true

RSpec.describe BabelReunited::UsageFuse do
  fab!(:user)

  before do
    enable_current_plugin
    Discourse.redis.flushdb
    SiteSetting.babel_reunited_daily_translation_limit = 100
    SiteSetting.babel_reunited_user_daily_translation_limit = 100
  end

  describe ".admit" do
    it "counts site and user together" do
      2.times { expect(described_class.admit(user)).to be_nil }

      expect(described_class.site_count).to eq(2)
      expect(described_class.user_count(user)).to eq(2)
    end

    it "admits up to the site limit and rejects after it" do
      SiteSetting.babel_reunited_daily_translation_limit = 2

      expect(described_class.admit(user)).to be_nil
      expect(described_class.admit(user)).to be_nil
      expect(described_class.admit(user)).to eq("site_daily_limit")
    end

    it "admits up to the user limit and rejects after it" do
      SiteSetting.babel_reunited_user_daily_translation_limit = 1

      expect(described_class.admit(user)).to be_nil
      expect(described_class.admit(user)).to eq("user_daily_limit")
    end

    it "tracks per-user counts independently" do
      SiteSetting.babel_reunited_user_daily_translation_limit = 1
      other_user = Fabricate(:user)

      expect(described_class.admit(user)).to be_nil
      expect(described_class.admit(user)).to eq("user_daily_limit")
      expect(described_class.admit(other_user)).to be_nil
    end

    it "charges the user fuse first, so an exhausted user spends no site quota" do
      SiteSetting.babel_reunited_user_daily_translation_limit = 1

      described_class.admit(user)
      described_class.admit(user)

      expect(described_class.site_count).to eq(1)
    end

    it "still counts an anonymous-free call against the site fuse" do
      expect(described_class.admit(nil)).to be_nil
      expect(described_class.site_count).to eq(1)
      expect(described_class.user_count(nil)).to eq(0)
    end

    it "is disabled when a limit is 0" do
      SiteSetting.babel_reunited_daily_translation_limit = 0
      SiteSetting.babel_reunited_user_daily_translation_limit = 0

      10.times { expect(described_class.admit(user)).to be_nil }
    end

    # The regression this guards: a separate "check the counter" step let
    # every concurrent caller read the same under-limit value and pass, so
    # the fuse leaked exactly when it was under load.
    it "hands the last slot to exactly one of two concurrent callers" do
      SiteSetting.babel_reunited_daily_translation_limit = 1
      SiteSetting.babel_reunited_user_daily_translation_limit = 100

      results = [described_class.admit(user), described_class.admit(user)]

      expect(results.count(nil)).to eq(1)
      expect(results).to include("site_daily_limit")
    end
  end
end
