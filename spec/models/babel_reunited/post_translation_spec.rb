# frozen_string_literal: true

RSpec.describe BabelReunited::PostTranslation do
  fab!(:user)
  fab!(:topic) { Fabricate(:topic, user: user) }
  fab!(:post) { Fabricate(:post, topic: topic, user: user) }

  before { enable_current_plugin }

  describe "validations" do
    it "requires language presence" do
      translation =
        Fabricate.build(:post_translation, post: post, language: nil, status: "translating")
      expect(translation).not_to be_valid
      expect(translation.errors[:language]).to be_present
    end

    it "validates language format with two-letter code" do
      translation = Fabricate.build(:post_translation, post: post, language: "en")
      expect(translation).to be_valid
    end

    it "validates language format with region code" do
      translation = Fabricate.build(:post_translation, post: post, language: "zh-cn")
      expect(translation).to be_valid
    end

    it "rejects invalid language format" do
      translation = Fabricate.build(:post_translation, post: post, language: "ENG")
      expect(translation).not_to be_valid
      expect(translation.errors[:language]).to include("must be a valid language code")
    end

    it "rejects language codes that are too long" do
      translation = Fabricate.build(:post_translation, post: post, language: "a" * 11)
      expect(translation).not_to be_valid
    end

    it "enforces uniqueness of post_id + language" do
      Fabricate(:post_translation, post: post, language: "es")
      duplicate = Fabricate.build(:post_translation, post: post, language: "es")
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:post_id]).to be_present
    end

    it "requires translated_content when status is completed" do
      translation =
        Fabricate.build(
          :post_translation,
          post: post,
          language: "fr",
          status: "completed",
          translated_content: nil,
        )
      expect(translation).not_to be_valid
      expect(translation.errors[:translated_content]).to be_present
    end

    it "allows blank translated_content when status is translating" do
      translation =
        Fabricate.build(
          :post_translation,
          post: post,
          language: "fr",
          status: "translating",
          translated_content: "",
        )
      expect(translation).to be_valid
    end

    it "validates translated_title max length" do
      translation =
        Fabricate.build(:post_translation, post: post, language: "fr", translated_title: "a" * 256)
      expect(translation).not_to be_valid
    end

    it "allows blank translated_title" do
      translation =
        Fabricate.build(:post_translation, post: post, language: "fr", translated_title: "")
      expect(translation).to be_valid
    end
  end

  describe "scopes" do
    fab!(:es_translation) { Fabricate(:post_translation, post: post, language: "es") }
    fab!(:fr_translation) { Fabricate(:post_translation, post: post, language: "fr") }

    describe ".by_language" do
      it "filters by language" do
        expect(described_class.by_language("es")).to contain_exactly(es_translation)
      end
    end

    describe ".recent" do
      it "orders by created_at desc" do
        results = described_class.recent
        expect(results.first.created_at).to be >= results.last.created_at
      end
    end
  end

  describe ".find_translation" do
    fab!(:translation) { Fabricate(:post_translation, post: post, language: "es") }

    it "finds translation by post_id and language" do
      expect(described_class.find_translation(post.id, "es")).to eq(translation)
    end

    it "returns nil when not found" do
      expect(described_class.find_translation(post.id, "fr")).to be_nil
    end
  end

  describe "#translating?" do
    it "returns true when status is translating" do
      translation =
        Fabricate(
          :post_translation,
          post: post,
          language: "de",
          status: "translating",
          translated_content: "",
        )
      expect(translation.translating?).to be true
    end

    it "returns false when status is completed" do
      translation = Fabricate(:post_translation, post: post, language: "de", status: "completed")
      expect(translation.translating?).to be false
    end
  end

  describe "#completed?" do
    it "returns true when status is completed" do
      translation = Fabricate(:post_translation, post: post, language: "de", status: "completed")
      expect(translation.completed?).to be true
    end

    it "returns false when status is translating" do
      translation =
        Fabricate(
          :post_translation,
          post: post,
          language: "de",
          status: "translating",
          translated_content: "",
        )
      expect(translation.completed?).to be false
    end
  end

  describe "#failed?" do
    it "returns true when status is failed" do
      translation =
        Fabricate(
          :post_translation,
          post: post,
          language: "de",
          status: "failed",
          translated_content: "",
        )
      expect(translation.failed?).to be true
    end
  end

  describe "#source_language_detected?" do
    it "returns true when source_language is present" do
      translation = Fabricate(:post_translation, post: post, language: "de", source_language: "en")
      expect(translation.source_language_detected?).to be true
    end

    it "returns false when source_language is blank" do
      translation = Fabricate(:post_translation, post: post, language: "de", source_language: nil)
      expect(translation.source_language_detected?).to be false
    end
  end

  describe "#provider_info" do
    it "returns provider_info from metadata" do
      info = { "model" => "gpt-4o" }
      translation =
        Fabricate(
          :post_translation,
          post: post,
          language: "de",
          metadata: {
            "provider_info" => info,
          },
        )
      expect(translation.provider_info).to eq(info)
    end

    it "returns empty hash when provider_info is absent" do
      translation = Fabricate(:post_translation, post: post, language: "de", metadata: {})
      expect(translation.provider_info).to eq({})
    end
  end

  describe "#translation_confidence" do
    it "returns confidence from metadata" do
      translation =
        Fabricate(:post_translation, post: post, language: "de", metadata: { "confidence" => 0.98 })
      expect(translation.translation_confidence).to eq(0.98)
    end

    it "returns 0.0 when confidence is absent" do
      translation = Fabricate(:post_translation, post: post, language: "de", metadata: {})
      expect(translation.translation_confidence).to eq(0.0)
    end
  end

  describe "#has_translated_title?" do
    it "returns true when translated_title is present" do
      translation =
        Fabricate(:post_translation, post: post, language: "de", translated_title: "Titel")
      expect(translation.has_translated_title?).to be true
    end

    it "returns false when translated_title is blank" do
      translation = Fabricate(:post_translation, post: post, language: "de", translated_title: "")
      expect(translation.has_translated_title?).to be false
    end
  end

  describe "#translated_title_or_original" do
    it "returns translated_title when present" do
      translation =
        Fabricate(:post_translation, post: post, language: "de", translated_title: "Titel")
      expect(translation.translated_title_or_original).to eq("Titel")
    end

    it "returns original topic title when translated_title is blank" do
      translation = Fabricate(:post_translation, post: post, language: "de", translated_title: "")
      expect(translation.translated_title_or_original).to eq(post.topic.title)
    end
  end
end
