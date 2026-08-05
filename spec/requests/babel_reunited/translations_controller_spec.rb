# frozen_string_literal: true

RSpec.describe BabelReunited::TranslationsController do
  fab!(:user)
  fab!(:admin)
  fab!(:topic) { Fabricate(:topic, user: user) }
  fab!(:post_record) { Fabricate(:post, topic: topic, user: user) }

  before { enable_current_plugin }

  describe "authentication" do
    it "allows anonymous index" do
      Fabricate(:post_translation, post: post_record, language: "es")
      get "/babel-reunited/posts/#{post_record.id}/translations.json"
      expect(response.status).to eq(200)
    end

    it "allows anonymous show" do
      Fabricate(:post_translation, post: post_record, language: "es")
      get "/babel-reunited/posts/#{post_record.id}/translations/es.json"
      expect(response.status).to eq(200)
    end

    it "allows anonymous translation_status" do
      get "/babel-reunited/posts/#{post_record.id}/translations/translation_status.json"
      expect(response.status).to eq(200)
    end

    it "denies anonymous reads of restricted posts" do
      private_category =
        Fabricate(
          :private_category,
          group: Fabricate(:group),
          topic_count: 0,
          post_count: 0
        )
      private_topic = Fabricate(:topic, category: private_category)
      private_post = Fabricate(:post, topic: private_topic)

      get "/babel-reunited/posts/#{private_post.id}/translations.json"
      expect(response.status).to eq(403)
    end

    it "requires login for create" do
      post "/babel-reunited/posts/#{post_record.id}/translations.json",
           params: {
             target_language: "es"
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
      post "/babel-reunited/user-preferred-language.json",
           params: {
             language: "es"
           }
      expect(response.status).to eq(403)
    end
  end

  describe "GET /babel-reunited/posts/:post_id/translations" do
    fab!(:translation) do
      Fabricate(:post_translation, post: post_record, language: "es")
    end

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

    it "withholds a body produced from content the post no longer has" do
      Fabricate(
        :post_translation,
        post: post_record,
        language: "de",
        status: "stale"
      )

      get "/babel-reunited/posts/#{post_record.id}/translations.json"

      languages = response.parsed_body.map { |t| t["language"] }
      expect(languages).to include("es")
      expect(languages).not_to include("de")
    end

    it "is not a way around the guard for anonymous readers" do
      Fabricate(
        :post_translation,
        post: post_record,
        language: "de",
        status: "stale",
        translated_content: "<p>Das Passwort lautet hunter2</p>"
      )

      get "/babel-reunited/posts/#{post_record.id}/translations.json"

      expect(response.status).to eq(200)
      expect(response.body).not_to include("hunter2")
    end
  end

  describe "GET /babel-reunited/posts/:post_id/translations/:language" do
    fab!(:translation) do
      Fabricate(:post_translation, post: post_record, language: "es")
    end

    before { sign_in(user) }

    it "returns the translation for the given language" do
      get "/babel-reunited/posts/#{post_record.id}/translations/es.json"
      expect(response.status).to eq(200)
    end

    it "returns 404 when translation not found" do
      get "/babel-reunited/posts/#{post_record.id}/translations/fr.json"
      expect(response.status).to eq(404)
    end

    it "withholds a body produced from content the post no longer has" do
      Fabricate(
        :post_translation,
        post: post_record,
        language: "de",
        status: "stale"
      )

      get "/babel-reunited/posts/#{post_record.id}/translations/de.json"
      expect(response.status).to eq(404)
    end
  end

  describe "POST /babel-reunited/posts/:post_id/translations" do
    before do
      sign_in(user)
      Jobs.run_later!
      Discourse.redis.flushdb
    end

    it "enqueues a translation job and returns queued status" do
      post "/babel-reunited/posts/#{post_record.id}/translations.json",
           params: {
             target_language: "es"
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
            target_language: "es"
          }
        )
      ).to be true
    end

    it "returns 400 when target_language is blank" do
      post "/babel-reunited/posts/#{post_record.id}/translations.json",
           params: {
             target_language: ""
           }
      expect(response.status).to eq(400)
      expect(response.parsed_body["error"]).to include(
        "Target language required"
      )
    end

    it "returns 400 for invalid language format" do
      post "/babel-reunited/posts/#{post_record.id}/translations.json",
           params: {
             target_language: "INVALID"
           }
      expect(response.status).to eq(400)
      expect(response.parsed_body["error"]).to include(
        "Invalid language code format"
      )
    end

    it "normalizes uppercase language codes" do
      post "/babel-reunited/posts/#{post_record.id}/translations.json",
           params: {
             target_language: "EN"
           }
      expect(response.status).to eq(200)
      expect(response.parsed_body["target_language"]).to eq("en")
    end

    it "rejects well-formed but unsupported language codes" do
      post "/babel-reunited/posts/#{post_record.id}/translations.json",
           params: {
             target_language: "eng"
           }
      expect(response.status).to eq(400)
      expect(response.parsed_body["error"]).to include("Unsupported language")
    end

    it "accepts supported three-letter language codes" do
      post "/babel-reunited/posts/#{post_record.id}/translations.json",
           params: {
             target_language: "fil"
           }

      expect(response.status).to eq(200)
      expect(
        job_enqueued?(
          job: Jobs::BabelReunited::TranslatePostJob,
          args: {
            post_id: post_record.id,
            target_language: "fil"
          }
        )
      ).to be true
    end

    it "accepts language codes with region" do
      post "/babel-reunited/posts/#{post_record.id}/translations.json",
           params: {
             target_language: "zh-cn"
           }

      expect(response.status).to eq(200)

      expect(
        job_enqueued?(
          job: Jobs::BabelReunited::TranslatePostJob,
          args: {
            post_id: post_record.id,
            target_language: "zh-cn"
          }
        )
      ).to be true
    end

    it "rejects force_update from non-staff and does not enqueue" do
      post "/babel-reunited/posts/#{post_record.id}/translations.json",
           params: {
             target_language: "es",
             force_update: "true"
           }

      expect(response.status).to eq(403)
      expect(response.parsed_body["error"]).to include(
        "force_update requires staff"
      )
      expect(
        job_enqueued?(
          job: Jobs::BabelReunited::TranslatePostJob,
          args: {
            post_id: post_record.id,
            target_language: "es",
            force_update: true
          }
        )
      ).to be false
    end

    it "passes through force_update for staff" do
      sign_in(admin)

      post "/babel-reunited/posts/#{post_record.id}/translations.json",
           params: {
             target_language: "es",
             force_update: "true"
           }

      expect(response.status).to eq(200)
      expect(response.parsed_body["force_update"]).to eq(true)
      expect(
        job_enqueued?(
          job: Jobs::BabelReunited::TranslatePostJob,
          args: {
            post_id: post_record.id,
            target_language: "es",
            force_update: true
          }
        )
      ).to be true
    end

    it "returns 403 for non-whitelisted category and does not enqueue job" do
      blocked_category = Fabricate(:category)
      topic_in_blocked =
        Fabricate(:topic, user: user, category: blocked_category)
      blocked_post = Fabricate(:post, topic: topic_in_blocked, user: user)

      allowed_category = Fabricate(:category)
      SiteSetting.babel_reunited_enabled_categories = allowed_category.id.to_s

      post "/babel-reunited/posts/#{blocked_post.id}/translations.json",
           params: {
             target_language: "es"
           }

      expect(response.status).to eq(403)
      expect(
        job_enqueued?(
          job: Jobs::BabelReunited::TranslatePostJob,
          args: {
            post_id: blocked_post.id,
            target_language: "es"
          }
        )
      ).to be false
    end

    it "succeeds for whitelisted category" do
      allowed_category = Fabricate(:category)
      topic_in_allowed =
        Fabricate(:topic, user: user, category: allowed_category)
      allowed_post = Fabricate(:post, topic: topic_in_allowed, user: user)

      SiteSetting.babel_reunited_enabled_categories = allowed_category.id.to_s

      post "/babel-reunited/posts/#{allowed_post.id}/translations.json",
           params: {
             target_language: "es"
           }

      expect(response.status).to eq(200)
    end

    it "rate limits translation requests" do
      RateLimiter
        .any_instance
        .stubs(:performed!)
        .raises(
          RateLimiter::LimitExceeded.new(1, "babel-reunited-translate", nil)
        )

      post "/babel-reunited/posts/#{post_record.id}/translations.json",
           params: {
             target_language: "es"
           }

      expect(response.status).to eq(429)
    end

    it "refuses a same-language manual request from a stale client" do
      BabelReunited.store_detected_locale(post_record, "zh-cn")

      post "/babel-reunited/posts/#{post_record.id}/translations.json",
           params: {
             target_language: "zh-cn"
           }

      expect(response.status).to eq(200)
      expect(response.parsed_body["status"]).to eq("noop")
      expect(response.parsed_body["reason"]).to eq("source_language")
      expect(response.parsed_body["detected_locale"]).to eq("zh-cn")
      expect(Jobs::BabelReunited::TranslatePostJob.jobs).to be_empty
      expect(BabelReunited::UsageFuse.site_count).to eq(0)
    end

    it "lets staff force a same-language translation to correct detection" do
      BabelReunited.store_detected_locale(post_record, "zh-cn")
      sign_in(admin)

      post "/babel-reunited/posts/#{post_record.id}/translations.json",
           params: {
             target_language: "zh-cn",
             force_update: "true"
           }

      expect(response.parsed_body["status"]).to eq("queued")
      expect(
        job_enqueued?(
          job: Jobs::BabelReunited::TranslatePostJob,
          args: {
            post_id: post_record.id,
            target_language: "zh-cn",
            force_update: true
          }
        )
      ).to be true
    end

    it "still allows same-language requests when the detection is stale" do
      BabelReunited.store_detected_locale(
        post_record,
        "zh-cn",
        raw_sha: "0" * 64
      )

      post "/babel-reunited/posts/#{post_record.id}/translations.json",
           params: {
             target_language: "zh-cn"
           }

      expect(response.parsed_body["status"]).to eq("queued")
    end

    it "records manual requests against the daily fuse" do
      post "/babel-reunited/posts/#{post_record.id}/translations.json",
           params: {
             target_language: "es"
           }

      expect(response.status).to eq(200)
      expect(BabelReunited::UsageFuse.site_count).to eq(1)
      expect(BabelReunited::UsageFuse.user_count(user)).to eq(1)
    end

    it "rejects manual requests once the user daily fuse trips" do
      SiteSetting.babel_reunited_user_daily_translation_limit = 1
      BabelReunited::UsageFuse.admit(user)

      post "/babel-reunited/posts/#{post_record.id}/translations.json",
           params: {
             target_language: "es"
           }

      expect(response.status).to eq(429)
      expect(response.parsed_body["error"]).to include(
        "Daily translation limit"
      )
      expect(Jobs::BabelReunited::TranslatePostJob.jobs).to be_empty
    end

    it "rejects manual requests once the site daily fuse trips" do
      SiteSetting.babel_reunited_daily_translation_limit = 1
      BabelReunited::UsageFuse.admit(Fabricate(:user))

      post "/babel-reunited/posts/#{post_record.id}/translations.json",
           params: {
             target_language: "es"
           }

      expect(response.status).to eq(429)
      expect(response.parsed_body["error"]).to include("Site-wide")
    end

    it "exempts staff from the daily fuses" do
      SiteSetting.babel_reunited_daily_translation_limit = 1
      BabelReunited::UsageFuse.admit(Fabricate(:user))
      sign_in(admin)

      post "/babel-reunited/posts/#{post_record.id}/translations.json",
           params: {
             target_language: "es"
           }

      expect(response.status).to eq(200)
      expect(BabelReunited::UsageFuse.site_count).to eq(1)
    end
  end

  describe "POST /babel-reunited/posts/:post_id/translations with trigger=view" do
    before do
      sign_in(user)
      Jobs.run_later!
      SiteSetting.babel_reunited_view_triggered_translation = true
      Discourse.redis.flushdb
    end

    def view_trigger(language = "es", target = post_record)
      post "/babel-reunited/posts/#{target.id}/translations.json",
           params: {
             target_language: language,
             trigger: "view"
           }
    end

    def expect_noop(reason)
      expect(response.status).to eq(200)
      expect(response.parsed_body["status"]).to eq("noop")
      expect(response.parsed_body["reason"]).to eq(reason)
      expect(Jobs::BabelReunited::TranslatePostJob.jobs).to be_empty
    end

    it "enqueues and reports queued for a missing translation" do
      view_trigger

      expect(response.status).to eq(200)
      expect(response.parsed_body["status"]).to eq("queued")
      expect(
        job_enqueued?(
          job: Jobs::BabelReunited::TranslatePostJob,
          args: {
            post_id: post_record.id,
            target_language: "es"
          }
        )
      ).to be true
      expect(BabelReunited::UsageFuse.site_count).to eq(1)
    end

    it "noops when the setting is disabled" do
      SiteSetting.babel_reunited_view_triggered_translation = false
      view_trigger
      expect_noop("disabled")
    end

    it "noops below the minimum trust level" do
      SiteSetting.babel_reunited_view_trigger_min_trust_level = 3
      user.update!(trust_level: TrustLevel[1])
      view_trigger
      expect_noop("trust_level")
    end

    it "noops when the post is already in the target language" do
      BabelReunited.store_detected_locale(post_record, "es")
      view_trigger
      expect_noop("source_language")
    end

    it "re-claims a translating record whose lease expired" do
      translation =
        BabelReunited::PostTranslation.create_or_update_record(
          post_record.id,
          "es"
        )
      translation.update_columns(
        updated_at:
          BabelReunited::PostTranslation.translation_lease.ago - 1.minute
      )

      view_trigger

      expect(response.parsed_body["status"]).to eq("queued")
      expect(
        job_enqueued?(
          job: Jobs::BabelReunited::TranslatePostJob,
          args: {
            post_id: post_record.id,
            target_language: "es"
          }
        )
      ).to be true
      expect(translation.reload.updated_at).to be > 1.minute.ago
    end

    it "noops while a translation is in flight" do
      BabelReunited::PostTranslation.create_or_update_record(
        post_record.id,
        "es"
      )
      view_trigger
      expect_noop("already_translating")
    end

    it "noops for permanent failures" do
      Fabricate(
        :post_translation,
        post: post_record,
        language: "es",
        status: "failed",
        translated_content: "",
        metadata: {
          "error_kind" => "permanent",
          "failed_at" => 2.hours.ago.iso8601
        }
      )
      view_trigger
      expect_noop("failed_not_retryable")
    end

    it "noops for transient failures inside the cooldown" do
      Fabricate(
        :post_translation,
        post: post_record,
        language: "es",
        status: "failed",
        translated_content: "",
        metadata: {
          "error_kind" => "transient",
          "failed_at" => 5.minutes.ago.iso8601,
          "failure_count" => 1
        }
      )
      view_trigger
      expect_noop("failed_not_retryable")
    end

    it "re-enqueues transient failures after the cooldown" do
      Fabricate(
        :post_translation,
        post: post_record,
        language: "es",
        status: "failed",
        translated_content: "",
        metadata: {
          "error_kind" => "transient",
          "failed_at" => 31.minutes.ago.iso8601,
          "failure_count" => 1
        }
      )
      view_trigger

      expect(response.parsed_body["status"]).to eq("queued")
    end

    it "claims stale translations atomically and re-enqueues once" do
      translation =
        Fabricate(
          :post_translation,
          post: post_record,
          language: "es",
          status: "stale"
        )

      view_trigger
      expect(response.parsed_body["status"]).to eq("queued")
      expect(translation.reload.status).to eq("translating")
      expect(translation.translated_content).to be_present
      expect(BabelReunited::UsageFuse.site_count).to eq(1)

      # A second viewer during the same run noops instead of stacking work.
      view_trigger
      expect(response.parsed_body["status"]).to eq("noop")
      expect(response.parsed_body["reason"]).to eq("already_translating")
      expect(BabelReunited::UsageFuse.site_count).to eq(1)
      expect(Jobs::BabelReunited::TranslatePostJob.jobs.length).to eq(1)
    end

    it "creates a translating claim for missing translations before the job runs" do
      view_trigger

      translation =
        BabelReunited::PostTranslation.find_translation(post_record.id, "es")
      expect(translation.status).to eq("translating")
    end

    it "does not consume the fuse for completed self-heal requests" do
      Fabricate(
        :post_translation,
        post: post_record,
        language: "es",
        status: "completed"
      )

      view_trigger

      expect(response.parsed_body["status"]).to eq("queued")
      expect(BabelReunited::UsageFuse.site_count).to eq(0)
      expect(
        job_enqueued?(
          job: Jobs::BabelReunited::TranslatePostJob,
          args: {
            post_id: post_record.id,
            target_language: "es"
          }
        )
      ).to be true
    end

    it "leaves stale records unclaimed when the fuse rejects the request" do
      SiteSetting.babel_reunited_daily_translation_limit = 1
      BabelReunited::UsageFuse.admit(Fabricate(:user))
      translation =
        Fabricate(
          :post_translation,
          post: post_record,
          language: "es",
          status: "stale"
        )

      view_trigger

      expect(response.parsed_body["reason"]).to eq("site_daily_limit")
      expect(translation.reload.status).to eq("stale")
    end

    # The regression this guards: a claim with no job behind it pins the
    # record in "translating" for a full lease — an hour on defaults, six at
    # the maximum configured provider timeout — and every later view noops
    # on it.
    it "releases a claim it could not turn into a job" do
      BabelReunited.expects(:enqueue_translation_jobs).raises(
        Redis::CannotConnectError.new("down")
      )
      translation =
        Fabricate(
          :post_translation,
          post: post_record,
          language: "es",
          status: "stale"
        )

      view_trigger

      expect(response.status).to eq(500)
      expect(translation.reload.status).to eq("stale")
    end

    # The regression this guards: rolling an expired lease back with a fresh
    # updated_at restarted the lease, locking the record for another full
    # one — the exact state the rollback exists to undo.
    it "restores an expired lease as expired, not as a fresh claim" do
      BabelReunited.expects(:enqueue_translation_jobs).raises(
        Redis::CannotConnectError.new("down")
      )
      expired_at = BabelReunited::PostTranslation.translation_lease.ago - 1.hour
      translation =
        Fabricate(
          :post_translation,
          post: post_record,
          language: "es",
          status: "translating"
        )
      translation.update_columns(updated_at: expired_at)

      view_trigger

      translation.reload
      expect(translation.status).to eq("translating")
      expect(translation.updated_at).to be_within(1.second).of(expired_at)
      expect(translation.translation_lease_expired?).to be true
    end

    # The regression this guards: charging the fuse before the claim made
    # every viewer who lost the race pay for a translation someone else runs.
    it "charges no daily slot to a request that loses the claim race" do
      Fabricate(
        :post_translation,
        post: post_record,
        language: "es",
        status: "translating"
      )

      view_trigger

      expect_noop("already_translating")
      expect(BabelReunited::UsageFuse.site_count).to eq(0)
      expect(BabelReunited::UsageFuse.user_count(user)).to eq(0)
    end

    it "releases the claim when the fuse rejects the winner" do
      SiteSetting.babel_reunited_daily_translation_limit = 1
      BabelReunited::UsageFuse.admit(Fabricate(:user))

      view_trigger

      expect_noop("site_daily_limit")
      expect(
        BabelReunited::PostTranslation.find_translation(post_record.id, "es")
      ).to be_nil
    end

    it "removes a claim it created when the job could not be enqueued" do
      BabelReunited.expects(:enqueue_translation_jobs).raises(
        Redis::CannotConnectError.new("down")
      )

      view_trigger

      expect(response.status).to eq(500)
      expect(
        BabelReunited::PostTranslation.find_translation(post_record.id, "es")
      ).to be_nil
    end

    it "noops when the user daily fuse trips" do
      SiteSetting.babel_reunited_user_daily_translation_limit = 1
      BabelReunited::UsageFuse.admit(user)
      view_trigger
      expect_noop("user_daily_limit")
    end

    it "noops when the site daily fuse trips" do
      SiteSetting.babel_reunited_daily_translation_limit = 1
      BabelReunited::UsageFuse.admit(Fabricate(:user))
      view_trigger
      expect_noop("site_daily_limit")
    end

    it "exempts staff from fuses and trust level" do
      SiteSetting.babel_reunited_view_trigger_min_trust_level = 4
      SiteSetting.babel_reunited_daily_translation_limit = 1
      BabelReunited::UsageFuse.admit(Fabricate(:user))
      sign_in(admin)

      view_trigger

      expect(response.parsed_body["status"]).to eq("queued")
    end

    it "applies the view-lane rate bucket" do
      RateLimiter
        .any_instance
        .stubs(:performed!)
        .raises(
          RateLimiter::LimitExceeded.new(
            1,
            "babel-reunited-view-translate",
            nil
          )
        )

      view_trigger

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
      expect(
        BabelReunited::PostTranslation.find_translation(post_record.id, "es")
      ).to be_nil
    end

    it "returns 404 when translation not found" do
      delete "/babel-reunited/posts/#{post_record.id}/translations/fr.json"
      expect(response.status).to eq(404)
    end

    # A job may be holding the row across a provider call; the tombstone is
    # what stops it from writing the finished translation right back.
    it "stamps a tombstone so an in-flight job cannot resurrect the row" do
      Fabricate(:post_translation, post: post_record, language: "es")
      before_delete = Time.current

      delete "/babel-reunited/posts/#{post_record.id}/translations/es.json"
      expect(response.status).to eq(200)
      expect(
        BabelReunited.translation_tombstoned_since?(
          post_record.id,
          "es",
          before_delete
        )
      ).to be true
      # A job started after the deletion is a fresh request and must not
      # defer to it.
      expect(
        BabelReunited.translation_tombstoned_since?(
          post_record.id,
          "es",
          Time.current
        )
      ).to be false
    end
  end

  # A translation into the post's own language is legacy data or the product
  # of a wrong detection, and it is the shape answer-mode output took. No
  # reader path may surface it — the read endpoints included.
  describe "same-language records" do
    before do
      Fabricate(:post_translation, post: post_record, language: "en")
      BabelReunited.store_detected_locale(post_record, "en")
    end

    it "does not list one in index" do
      get "/babel-reunited/posts/#{post_record.id}/translations.json"

      expect(response.status).to eq(200)
      languages = response.parsed_body.map { |t| t["language"] }
      expect(languages).not_to include("en")
    end

    it "does not serve one from show" do
      get "/babel-reunited/posts/#{post_record.id}/translations/en.json"
      expect(response.status).to eq(404)
    end

    it "still serves a genuine translation of the same post" do
      Fabricate(:post_translation, post: post_record, language: "es")

      get "/babel-reunited/posts/#{post_record.id}/translations/es.json"
      expect(response.status).to eq(200)
    end
  end

  # The category setting scopes the whole feature: excluded categories serve
  # no stored translations, so the read endpoints match the hidden UI, the
  # withheld serializer payloads, and the blocked generation.
  describe "category whitelist" do
    fab!(:allowed_category, :category)

    before do
      Fabricate(:post_translation, post: post_record, language: "es")
      SiteSetting.babel_reunited_enabled_categories = allowed_category.id.to_s
    end

    it "does not serve stored translations from an excluded category" do
      get "/babel-reunited/posts/#{post_record.id}/translations.json"
      expect(response.status).to eq(403)

      get "/babel-reunited/posts/#{post_record.id}/translations/es.json"
      expect(response.status).to eq(403)

      get "/babel-reunited/posts/#{post_record.id}/translations/translation_status.json"
      expect(response.status).to eq(403)
    end

    # Removing stock data is cleanup, not a translation feature: it must not
    # require re-enabling the category first.
    it "still allows deleting a translation in an excluded category" do
      sign_in(admin)

      delete "/babel-reunited/posts/#{post_record.id}/translations/es.json"
      expect(response.status).to eq(200)
      expect(
        BabelReunited::PostTranslation.find_translation(post_record.id, "es")
      ).to be_nil
    end
  end

  describe "GET /babel-reunited/user-preferred-language" do
    before { sign_in(user) }

    it "returns preference when set" do
      Fabricate(
        :user_preferred_language,
        user: user,
        language: "es",
        enabled: true
      )

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
      post "/babel-reunited/user-preferred-language.json",
           params: {
             language: "es"
           }
      expect(response.status).to eq(200)

      json = response.parsed_body
      expect(json["success"]).to be true
      expect(json["language"]).to eq("es")
    end

    it "sets a language preference with region code" do
      post "/babel-reunited/user-preferred-language.json",
           params: {
             language: "zh-cn"
           }
      expect(response.status).to eq(200)

      json = response.parsed_body
      expect(json["language"]).to eq("zh-cn")
    end

    it "returns 400 for invalid language format" do
      post "/babel-reunited/user-preferred-language.json",
           params: {
             language: "INVALID"
           }
      expect(response.status).to eq(400)
    end

    it "returns 400 for well-formed but unsupported language" do
      post "/babel-reunited/user-preferred-language.json",
           params: {
             language: "eng"
           }
      expect(response.status).to eq(400)
      expect(response.parsed_body["error"]).to include("Unsupported language")
    end

    it "sets a supported three-letter language preference" do
      post "/babel-reunited/user-preferred-language.json",
           params: {
             language: "yue"
           }
      expect(response.status).to eq(200)
      expect(response.parsed_body["language"]).to eq("yue")
    end

    it "updates existing preference" do
      Fabricate(:user_preferred_language, user: user, language: "es")

      post "/babel-reunited/user-preferred-language.json",
           params: {
             language: "fr"
           }
      expect(response.status).to eq(200)
      expect(response.parsed_body["language"]).to eq("fr")
    end

    it "updates enabled without changing language" do
      Fabricate(
        :user_preferred_language,
        user: user,
        language: "es",
        enabled: true
      )

      post "/babel-reunited/user-preferred-language.json",
           params: {
             enabled: "false"
           }

      expect(response.status).to eq(200)
      expect(response.parsed_body["language"]).to eq("es")
      expect(response.parsed_body["enabled"]).to be false
    end
  end

  describe "GET /babel-reunited/posts/:post_id/translations/translation_status" do
    before { sign_in(user) }

    it "returns translation status" do
      Fabricate(
        :post_translation,
        post: post_record,
        language: "es",
        status: "completed"
      )
      Fabricate(
        :post_translation,
        post: post_record,
        language: "fr",
        status: "translating",
        translated_content: ""
      )

      get "/babel-reunited/posts/#{post_record.id}/translations/translation_status.json"
      expect(response.status).to eq(200)

      json = response.parsed_body
      expect(json["post_id"]).to eq(post_record.id)
      expect(json["pending_translations"]).to contain_exactly("fr")
      expect(json["available_translations"]).to contain_exactly("es", "fr")
    end
  end

  describe "GET /babel-reunited/posts/:post_id/translations/translation_status with no translations" do
    before { sign_in(user) }

    it "returns empty arrays when no translations exist" do
      get "/babel-reunited/posts/#{post_record.id}/translations/translation_status.json"
      expect(response.status).to eq(200)

      json = response.parsed_body
      expect(json["post_id"]).to eq(post_record.id)
      expect(json["pending_translations"]).to eq([])
      expect(json["available_translations"]).to eq([])
    end
  end

  describe "permission checks" do
    it "returns 403 when user cannot see post" do
      private_category =
        Fabricate(
          :private_category,
          group: Fabricate(:group),
          topic_count: 0,
          post_count: 0
        )
      private_topic = Fabricate(:topic, category: private_category)
      private_post = Fabricate(:post, topic: private_topic)

      sign_in(user)
      get "/babel-reunited/posts/#{private_post.id}/translations.json"
      expect(response.status).to eq(403)
    end
  end
end
