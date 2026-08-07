# frozen_string_literal: true

RSpec.describe "babel_reunited:backfill_detected_locales" do
  fab!(:user)
  fab!(:topic) { Fabricate(:topic, user: user) }
  fab!(:post_record) do
    Fabricate(
      :post,
      topic: topic,
      user: user,
      raw:
        "This is a long enough English sentence for language detection to work."
    )
  end

  let(:task) { Rake::Task["babel_reunited:backfill_detected_locales"] }

  before do
    enable_current_plugin
    SiteSetting.babel_reunited_enabled = true
    # A configured provider is the normal state; the task refuses to start
    # without one, which two examples below check deliberately.
    SiteSetting.babel_reunited_openai_api_key = "sk-test-key"
    SiteSetting.babel_reunited_preset_model = "gpt-4o"
    # The task paces itself with real sleeps. A high allowance keeps the pause
    # between posts down to a tenth of a second without stubbing out the very
    # pacing these examples run through.
    SiteSetting.babel_reunited_rate_limit_per_minute = 1000
    Discourse.redis.flushdb
    task.reenable
  end

  after do
    ENV.delete("DRY_RUN")
    ENV.delete("LIMIT")
    ENV.delete("PER_MINUTE")
    # The task exits the process on a bad value, so a leaked one does not fail
    # one example -- it kills the run at whichever example comes next.
    ENV.delete("BATCH_SIZE")
  end

  def stub_detection(reply)
    stub_request(:post, "https://api.openai.com/v1/chat/completions").to_return(
      status: 200,
      headers: {
        "Content-Type" => "application/json"
      },
      body: {
        choices: [{ message: { content: reply }, finish_reason: "stop" }],
        usage: {
          total_tokens: 42
        }
      }.to_json
    )
  end

  def stub_detection_failure
    stub_request(:post, "https://api.openai.com/v1/chat/completions").to_return(
      status: 500
    )
  end

  # Rake appends actions rather than replacing them, and some environments
  # evaluate every plugin rake file twice -- forty tasks in one deploy
  # checkout carry two actions each, core's assets:precompile among them. A
  # second action here means every run happens twice: LIMIT=20 spends for 40.
  it "does not register its tasks twice if the file is loaded again" do
    before_count = task.actions.size

    # load, not require_relative: require would no-op the second time, which
    # is exactly the thing this example has to make happen.
    # rubocop:disable Discourse/Plugins/UseRequireRelative
    load Rails
           .root
           .join("plugins/babel-reunited/lib/tasks/babel_reunited.rake")
           .to_s
    # rubocop:enable Discourse/Plugins/UseRequireRelative

    expect(
      Rake::Task["babel_reunited:backfill_detected_locales"].actions.size
    ).to eq(before_count)
  end

  # The run holds one process for an hour while the switch is thrown in
  # another. Settings are cached per process and the notification carrying the
  # change is asynchronous, so the cached value can still say enabled while
  # the authoritative one does not -- and the difference is another post's
  # content already sent.
  it "consults the authoritative switch, not this process's cached copy" do
    ENV["DRY_RUN"] = "false"
    Fabricate(:post_translation, post: post_record, language: "es")
    second =
      Fabricate(
        :post,
        topic: topic,
        user: user,
        raw: "Another long enough English sentence for detection to work on."
      )
    Fabricate(:post_translation, post: second, language: "es")

    calls = 0
    stub_request(
      :post,
      "https://api.openai.com/v1/chat/completions"
    ).to_return do
      calls += 1
      {
        status: 200,
        headers: {
          "Content-Type" => "application/json"
        },
        body: {
          choices: [{ message: { content: "en" }, finish_reason: "stop" }],
          usage: {
            total_tokens: 42
          }
        }.to_json
      }
    end

    # Stands in for the admin having thrown the switch elsewhere: the cached
    # read still says enabled, and only the authoritative reload sees it.
    original = SiteSetting.method(:refresh!)
    thrown = false
    SiteSetting.define_singleton_method(:refresh!) do
      SiteSetting.babel_reunited_enabled = false if thrown
      thrown = true
      nil
    end

    begin
      expect { task.invoke }.to output(/Plugin was disabled mid-run/).to_stdout
    ensure
      SiteSetting.define_singleton_method(:refresh!, original)
    end

    expect(calls).to eq(1)
  end

  it "defaults to a dry run that detects nothing" do
    Fabricate(:post_translation, post: post_record, language: "es")

    expect { task.invoke }.to output(/DRY RUN/).to_stdout
    expect(BabelReunited.detection_current?(post_record.reload)).to be false
  end

  it "detects in this process and records the locale" do
    ENV["DRY_RUN"] = "false"
    Fabricate(:post_translation, post: post_record, language: "es")
    stub_detection("en")

    expect { task.invoke }.to output(/Detected: 1/).to_stdout

    post_record.reload
    expect(BabelReunited.detected_locale_for(post_record)).to eq("en")
    expect(BabelReunited.detection_current?(post_record)).to be true
  end

  # The backfill runs for an hour against a live forum, so a page open at the
  # moment a post is detected has to be corrected the same way the job
  # corrects it -- otherwise the reader is still offered a translation into
  # the language the post is already written in.
  it "publishes a detected locale so open pages stop offering it" do
    ENV["DRY_RUN"] = "false"
    Fabricate(:post_translation, post: post_record, language: "es")
    stub_detection("en")

    messages =
      MessageBus.track_publish("/post-translations/#{post_record.id}") do
        task.invoke
      end

    expect(messages.length).to eq(1)
    expect(messages.first.data[:detected_locale]).to eq("en")
  end

  it "stays quiet about an undetermined answer" do
    ENV["DRY_RUN"] = "false"
    Fabricate(:post_translation, post: post_record, language: "es")
    stub_detection("und")

    messages =
      MessageBus.track_publish("/post-translations/#{post_record.id}") do
        task.invoke
      end

    expect(messages).to be_empty
  end

  # Pacing on the allowance the run started with keeps asking at the old rate
  # after an admin lowers it, and every ask the limiter refuses spends part of
  # a post's retry budget for nothing. Timing is the only way to observe a
  # pace, so the margin here is deliberately wide: 0.12s under the startup
  # value against 1.0s under the lowered one.
  it "re-reads the site allowance instead of pacing on the startup value" do
    ENV["DRY_RUN"] = "false"
    Fabricate(:post_translation, post: post_record, language: "es")

    stub_request(
      :post,
      "https://api.openai.com/v1/chat/completions"
    ).to_return do
      SiteSetting.babel_reunited_rate_limit_per_minute = 60
      {
        status: 200,
        headers: {
          "Content-Type" => "application/json"
        },
        body: {
          choices: [{ message: { content: "en" }, finish_reason: "stop" }],
          usage: {
            total_tokens: 42
          }
        }.to_json
      }
    end

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    task.invoke
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    expect(BabelReunited.detected_locale_for(post_record.reload)).to eq("en")
    expect(elapsed).to be > 0.5
  end

  # The switch is what an admin throws when something is wrong. A run that
  # checked it once at startup would keep shipping content to the provider
  # for the rest of the hour.
  it "stops sending as soon as the plugin is switched off mid-run" do
    ENV["DRY_RUN"] = "false"
    Fabricate(:post_translation, post: post_record, language: "es")
    second =
      Fabricate(
        :post,
        topic: topic,
        user: user,
        raw: "Another long enough English sentence for detection to work on."
      )
    Fabricate(:post_translation, post: second, language: "es")

    calls = 0
    stub_request(
      :post,
      "https://api.openai.com/v1/chat/completions"
    ).to_return do
      calls += 1
      SiteSetting.babel_reunited_enabled = false
      {
        status: 200,
        headers: {
          "Content-Type" => "application/json"
        },
        body: {
          choices: [{ message: { content: "en" }, finish_reason: "stop" }],
          usage: {
            total_tokens: 42
          }
        }.to_json
      }
    end

    expect { task.invoke }.to output(/Plugin was disabled mid-run/).to_stdout

    expect(calls).to eq(1)
  end

  # A taken slot ends the post's turn rather than starting a wait. Sending
  # again after one would mean sending the sample captured before it -- so an
  # edit made during the wait reaches the provider as the post's current
  # content, which is the thing every other guard here exists to prevent.
  it "leaves a rate-limited post for a re-run without sending anything" do
    ENV["DRY_RUN"] = "false"
    Fabricate(:post_translation, post: post_record, language: "es")

    bodies = []
    stub_request(
      :post,
      "https://api.openai.com/v1/chat/completions"
    ).to_return do |req|
      bodies << req.body.to_s
      { status: 200, body: "{}" }
    end

    limiter = BabelReunited::RateLimiter
    original = limiter.method(:perform_request_if_allowed)
    refused = false
    target = post_record
    limiter.define_singleton_method(:perform_request_if_allowed) do
      next true if refused

      refused = true
      # The author replaces the post while the slot is unavailable.
      target.update_columns(
        raw:
          "Completely different replacement text, also long enough to detect."
      )
      false
    end

    begin
      expect { task.invoke }.to output(/Failed, left for a re-run: 1/).to_stdout
    ensure
      limiter.define_singleton_method(:perform_request_if_allowed, original)
    end

    expect(bodies).to be_empty
    expect(BabelReunited.detection_current?(post_record.reload)).to be false
  end

  # An edit during the call triggers its own detection, so by the time this
  # answer comes back the post may already carry a newer, correct one.
  # Writing the older answer over it would not just miss -- it would destroy
  # a result that was right and leave the post needing detection again.
  it "discards an answer whose content changed while the call was in flight" do
    ENV["DRY_RUN"] = "false"
    Fabricate(:post_translation, post: post_record, language: "es")

    edited_raw = "Ceci est une phrase francaise assez longue pour la detection."
    fake_service = Object.new
    target = post_record
    fake_service.define_singleton_method(:detectable?) { true }
    fake_service.define_singleton_method(:call) do
      # The reader edits, and the edit's own detection lands first.
      target.update_columns(raw: edited_raw)
      BabelReunited.store_detected_locale(target, "fr")
      BabelReunited::LanguageDetectionService::Result.new(locale: "en")
    end
    BabelReunited::LanguageDetectionService.stubs(:new).returns(fake_service)

    expect { task.invoke }.to output(
      /Superseded mid-detection, discarded: 1/
    ).to_stdout

    post_record.reload
    expect(BabelReunited.detected_locale_for(post_record)).to eq("fr")
    expect(BabelReunited.detection_current?(post_record)).to be true
  end

  # The prompt asks for "und" when the language cannot be determined, and the
  # model may name a real language outside the supported list. Both are
  # answers about the content: without recording them the post stays
  # outstanding and every re-run pays to ask the same question again.
  it "records an undetermined answer instead of retrying it forever" do
    ENV["DRY_RUN"] = "false"
    Fabricate(:post_translation, post: post_record, language: "es")
    stub_detection("und")

    expect { task.invoke }.to output(
      /No supported language \(recorded, will not be retried\): 1/
    ).to_stdout

    post_record.reload
    expect(BabelReunited.detection_current?(post_record)).to be true
    # Readers still see an unlabelled post: this is not a language.
    expect(BabelReunited.detected_locale_for(post_record)).to be_nil

    task.reenable
    expect { task.invoke }.to output(
      /answered as no supported language: 1.*still needing detection: 0/m
    ).to_stdout
  end

  # No queue means no retry to inherit: leaving the post unrecorded is what
  # makes the next run pick it up.
  it "leaves a failed detection for a re-run" do
    ENV["DRY_RUN"] = "false"
    Fabricate(:post_translation, post: post_record, language: "es")
    stub_detection_failure

    expect { task.invoke }.to output(/Failed, left for a re-run: 1/).to_stdout

    expect(BabelReunited.detection_current?(post_record.reload)).to be false
  end

  it "counts a post that already has current detection as done" do
    ENV["DRY_RUN"] = "false"
    Fabricate(:post_translation, post: post_record, language: "es")
    BabelReunited.store_detected_locale(post_record, "en")

    expect { task.invoke }.to output(
      /still needing detection: 0.*Nothing left to detect/m
    ).to_stdout
  end

  it "ignores posts that have no translations at all" do
    ENV["DRY_RUN"] = "false"
    Fabricate(:post, topic: topic, user: user)

    expect { task.invoke }.to output(/Posts with translations: 0/).to_stdout
  end

  # Detection ships post content to a third-party provider, so the backfill
  # refuses the same posts every other egress does.
  it "leaves hidden posts alone" do
    ENV["DRY_RUN"] = "false"
    Fabricate(:post_translation, post: post_record, language: "es")
    post_record.update!(hidden: true)

    expect { task.invoke }.to output(/not eligible.*: 1/).to_stdout
    expect(BabelReunited.detection_current?(post_record.reload)).to be false
  end

  # Only a code block: every attempt fails identically, so counting it as
  # outstanding would keep the runbook from ever reaching zero.
  it "counts content that can never be detected as such, not as outstanding" do
    ENV["DRY_RUN"] = "false"
    post_record.update!(raw: "[code]\nx=1\n[/code]")
    Fabricate(:post_translation, post: post_record, language: "es")

    expect { task.invoke }.to output(
      /too short to ever detect: 1.*still needing detection: 0/m
    ).to_stdout
  end

  it "refuses to start when detection is not configured" do
    ENV["DRY_RUN"] = "false"
    SiteSetting.babel_reunited_openai_api_key = ""
    SiteSetting.babel_reunited_anthropic_api_key = ""
    Fabricate(:post_translation, post: post_record, language: "es")

    expect {
      expect { task.invoke }.to output(/API key not configured/).to_stdout
    }.to raise_error(SystemExit)
  end

  it "still surveys the scale in a dry run without a provider" do
    SiteSetting.babel_reunited_openai_api_key = ""
    SiteSetting.babel_reunited_anthropic_api_key = ""
    Fabricate(:post_translation, post: post_record, language: "es")

    expect { task.invoke }.to output(/still needing detection: 1/).to_stdout
  end

  # Pacing above the allowance is not pacing: the calls would arrive at a rate
  # the limiter refuses, and every refusal is a wait anyway.
  it "clamps PER_MINUTE to the site rate limit" do
    ENV["DRY_RUN"] = "false"
    SiteSetting.babel_reunited_rate_limit_per_minute = 2
    ENV["PER_MINUTE"] = "100"
    Fabricate(:post_translation, post: post_record, language: "es")
    BabelReunited.store_detected_locale(post_record, "en")

    expect { task.invoke }.to output(/using 2/).to_stdout
  end

  it "rejects a nonsensical BATCH_SIZE" do
    ENV["BATCH_SIZE"] = "0"

    expect {
      expect { task.invoke }.to output(
        /BATCH_SIZE must be a positive integer/
      ).to_stdout
    }.to raise_error(SystemExit)
  end

  it "honors LIMIT when sizing a first pass" do
    ENV["LIMIT"] = "1"
    Fabricate(:post_translation, post: post_record, language: "es")
    second = Fabricate(:post, topic: topic, user: user)
    Fabricate(:post_translation, post: second, language: "es")

    expect { task.invoke }.to output(
      /still needing detection: 1.*stopped early at LIMIT/m
    ).to_stdout
  end

  # LIMIT is the cautious first pass on a production run. Reporting one post
  # and then detecting the whole forum is the opposite of cautious.
  it "stops the run at LIMIT" do
    ENV["DRY_RUN"] = "false"
    ENV["LIMIT"] = "1"
    Fabricate(:post_translation, post: post_record, language: "es")
    second =
      Fabricate(
        :post,
        topic: topic,
        user: user,
        raw: "Another long enough English sentence for detection to work on."
      )
    Fabricate(:post_translation, post: second, language: "es")
    stub_detection("en")

    expect { task.invoke }.to output(/Detected: 1/).to_stdout

    detected =
      [post_record, second].count do |post|
        BabelReunited.detection_current?(post.reload)
      end
    expect(detected).to eq(1)
  end
end
