# frozen_string_literal: true

RSpec.describe BabelReunited::TranslationsController do
  fab!(:user)
  fab!(:admin)
  fab!(:topic) { Fabricate(:topic, user: user) }
  fab!(:post_record) { Fabricate(:post, topic: topic, user: user) }

  before { enable_current_plugin }

  describe "authentication" do
    it "requires login for index" do
      get "/babel-reunited/posts/#{post_record.id}/translations.json"
      expect(response.status).to eq(403)
    end

    it "requires login for show" do
      get "/babel-reunited/posts/#{post_record.id}/translations/es.json"
      expect(response.status).to eq(403)
    end

    it "requires login for create" do
      post "/babel-reunited/posts/#{post_record.id}/translations.json",
           params: {
             target_language: "es",
           }
      expect(response.status).to eq(403)
    end

    it "requires login for destroy" do
      delete "/babel-reunited/posts/#{post_record.id}/translations/es.json"
      expect(response.status).to eq(403)
    end

    it "requires login for get_user_preferred_language" do
      get "/babel-reunited/user-preferred-language.json"
      expect(response.status).to eq(403)
    end

    it "requires login for set_user_preferred_language" do
      post "/babel-reunited/user-preferred-language.json", params: { language: "es" }
      expect(response.status).to eq(403)
    end

    it "requires login for translation_status" do
      get "/babel-reunited/posts/#{post_record.id}/translations/translation_status.json"
      expect(response.status).to eq(403)
    end
  end

  describe "GET /babel-reunited/posts/:post_id/translations" do
    fab!(:translation) { Fabricate(:post_translation, post: post_record, language: "es") }

    before { sign_in(user) }

    it "returns translations for the post" do
      get "/babel-reunited/posts/#{post_record.id}/translations.json"
      expect(response.status).to eq(200)
      expect(response.parsed_body).to be_present
    end

    it "returns 404 for non-existent post" do
      get "/babel-reunited/posts/-1/translations.json"
      expect(response.status).to eq(404)
    end
  end

  describe "GET /babel-reunited/posts/:post_id/translations/:language" do
    fab!(:translation) { Fabricate(:post_translation, post: post_record, language: "es") }

    before { sign_in(user) }

    it "returns the translation for the given language" do
      get "/babel-reunited/posts/#{post_record.id}/translations/es.json"
      expect(response.status).to eq(200)
    end

    it "returns 404 when translation not found" do
      get "/babel-reunited/posts/#{post_record.id}/translations/fr.json"
      expect(response.status).to eq(404)
    end
  end

  describe "POST /babel-reunited/posts/:post_id/translations" do
    before do
      sign_in(user)
      Jobs.run_later!
    end

    it "enqueues a translation job and returns queued status" do
      post "/babel-reunited/posts/#{post_record.id}/translations.json",
           params: {
             target_language: "es",
           }

      expect(response.status).to eq(200)

      json = response.parsed_body
      expect(json["status"]).to eq("queued")
      expect(json["target_language"]).to eq("es")
      expect(json["post_id"]).to eq(post_record.id)

      expect(
        job_enqueued?(
          job: Jobs::BabelReunited::TranslatePostJob,
          args: {
            post_id: post_record.id,
            target_language: "es",
          },
        ),
      ).to be true
    end

    it "returns 400 when target_language is blank" do
      post "/babel-reunited/posts/#{post_record.id}/translations.json",
           params: {
             target_language: "",
           }
      expect(response.status).to eq(400)
      expect(response.parsed_body["error"]).to include("Target language required")
    end

    it "returns 400 for invalid language format" do
      post "/babel-reunited/posts/#{post_record.id}/translations.json",
           params: {
             target_language: "INVALID",
           }
      expect(response.status).to eq(400)
      expect(response.parsed_body["error"]).to include("Invalid language code format")
    end

    it "accepts language codes with region" do
      post "/babel-reunited/posts/#{post_record.id}/translations.json",
           params: {
             target_language: "zh-cn",
           }

      expect(response.status).to eq(200)

      expect(
        job_enqueued?(
          job: Jobs::BabelReunited::TranslatePostJob,
          args: {
            post_id: post_record.id,
            target_language: "zh-cn",
          },
        ),
      ).to be true
    end

    it "rate limits translation requests" do
      RateLimiter.enable

      11.times do |i|
        post "/babel-reunited/posts/#{post_record.id}/translations.json",
             params: {
               target_language: "es",
             }
        break if response.status == 429
      end

      expect(response.status).to eq(429)
    end
  end

  describe "DELETE /babel-reunited/posts/:post_id/translations/:language" do
    before { sign_in(user) }

    it "deletes the translation" do
      Fabricate(:post_translation, post: post_record, language: "es")

      delete "/babel-reunited/posts/#{post_record.id}/translations/es.json"
      expect(response.status).to eq(200)
      expect(response.parsed_body["message"]).to eq("Translation deleted")
      expect(BabelReunited::PostTranslation.find_translation(post_record.id, "es")).to be_nil
    end

    it "returns 404 when translation not found" do
      delete "/babel-reunited/posts/#{post_record.id}/translations/fr.json"
      expect(response.status).to eq(404)
    end
  end

  describe "GET /babel-reunited/user-preferred-language" do
    before { sign_in(user) }

    it "returns preference when set" do
      Fabricate(:user_preferred_language, user: user, language: "es", enabled: true)

      get "/babel-reunited/user-preferred-language.json"
      expect(response.status).to eq(200)

      json = response.parsed_body
      expect(json["language"]).to eq("es")
      expect(json["enabled"]).to be true
    end

    it "returns defaults when no preference set" do
      get "/babel-reunited/user-preferred-language.json"
      expect(response.status).to eq(200)

      json = response.parsed_body
      expect(json["language"]).to be_nil
      expect(json["enabled"]).to be true
    end
  end

  describe "POST /babel-reunited/user-preferred-language" do
    before { sign_in(user) }

    it "sets a valid language preference" do
      post "/babel-reunited/user-preferred-language.json", params: { language: "es" }
      expect(response.status).to eq(200)

      json = response.parsed_body
      expect(json["success"]).to be true
      expect(json["language"]).to eq("es")
    end

    it "sets a language preference with region code" do
      post "/babel-reunited/user-preferred-language.json", params: { language: "zh-cn" }
      expect(response.status).to eq(200)

      json = response.parsed_body
      expect(json["language"]).to eq("zh-cn")
    end

    it "returns 400 for invalid language format" do
      post "/babel-reunited/user-preferred-language.json", params: { language: "INVALID" }
      expect(response.status).to eq(400)
    end

    it "updates existing preference" do
      Fabricate(:user_preferred_language, user: user, language: "es")

      post "/babel-reunited/user-preferred-language.json", params: { language: "fr" }
      expect(response.status).to eq(200)
      expect(response.parsed_body["language"]).to eq("fr")
    end
  end

  describe "GET /babel-reunited/posts/:post_id/translations/translation_status" do
    before { sign_in(user) }

    it "returns translation status" do
      Fabricate(:post_translation, post: post_record, language: "es", status: "completed")
      Fabricate(
        :post_translation,
        post: post_record,
        language: "fr",
        status: "translating",
        translated_content: "",
      )

      get "/babel-reunited/posts/#{post_record.id}/translations/translation_status.json"
      expect(response.status).to eq(200)

      json = response.parsed_body
      expect(json["post_id"]).to eq(post_record.id)
      expect(json["pending_translations"]).to contain_exactly("fr")
      expect(json["available_translations"]).to contain_exactly("es", "fr")
    end
  end

  describe "permission checks" do
    it "returns 403 when user cannot see post" do
      private_category =
        Fabricate(:private_category, group: Fabricate(:group), topic_count: 0, post_count: 0)
      private_topic = Fabricate(:topic, category: private_category)
      private_post = Fabricate(:post, topic: private_topic)

      sign_in(user)
      get "/babel-reunited/posts/#{private_post.id}/translations.json"
      expect(response.status).to eq(403)
    end
  end
end
