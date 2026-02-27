# frozen_string_literal: true

RSpec.describe BabelReunited::UserPreferredLanguage do
  fab!(:user)

  before { enable_current_plugin }

  describe "validations" do
    it "validates language max length" do
      pref = Fabricate.build(:user_preferred_language, user: user, language: "a" * 11)
      expect(pref).not_to be_valid
      expect(pref.errors[:language]).to be_present
    end

    it "validates enabled inclusion" do
      pref = Fabricate.build(:user_preferred_language, user: user, enabled: nil)
      expect(pref).not_to be_valid
      expect(pref.errors[:enabled]).to be_present
    end

    it "accepts valid attributes" do
      pref = Fabricate.build(:user_preferred_language, user: user, language: "zh-cn", enabled: true)
      expect(pref).to be_valid
    end
  end

  describe "associations" do
    it "belongs to user" do
      pref = Fabricate(:user_preferred_language, user: user)
      expect(pref.user).to eq(user)
    end
  end
end
