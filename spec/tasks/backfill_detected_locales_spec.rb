# frozen_string_literal: true

RSpec.describe "babel_reunited:backfill_detected_locales" do
  fab!(:user)
  fab!(:topic) { Fabricate(:topic, user: user) }
  fab!(:post_record) { Fabricate(:post, topic: topic, user: user) }

  let(:task) { Rake::Task["babel_reunited:backfill_detected_locales"] }

  before do
    enable_current_plugin
    SiteSetting.babel_reunited_enabled = true
    # A configured provider is the normal state; the task refuses to start
    # without one, which two examples below check deliberately.
    SiteSetting.babel_reunited_openai_api_key = "sk-test-key"
    SiteSetting.babel_reunited_preset_model = "gpt-4o"
    Discourse.redis.flushdb
    Jobs.run_later!
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

  def dispatcher_jobs
    Jobs::BabelReunited::BackfillDetectionDispatcher.jobs
  end

  it "defaults to a dry run that starts nothing" do
    Fabricate(:post_translation, post: post_record, language: "es")

    expect { task.invoke }.to output(/DRY RUN/).to_stdout
    expect(dispatcher_jobs).to be_empty
  end

  it "starts a dispatcher when there is work" do
    ENV["DRY_RUN"] = "false"
    Fabricate(:post_translation, post: post_record, language: "es")

    expect { task.invoke }.to output(/Started the dispatcher/).to_stdout
    expect(dispatcher_jobs.size).to eq(1)
  end

  it "counts a post that already has current detection as done" do
    ENV["DRY_RUN"] = "false"
    Fabricate(:post_translation, post: post_record, language: "es")
    BabelReunited.store_detected_locale(post_record, "en")

    expect { task.invoke }.to output(
      /still needing detection: 0.*Nothing left to detect/m
    ).to_stdout
    expect(dispatcher_jobs).to be_empty
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
    expect(dispatcher_jobs).to be_empty
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
    expect(dispatcher_jobs).to be_empty
  end

  it "refuses to start when detection is not configured" do
    ENV["DRY_RUN"] = "false"
    SiteSetting.babel_reunited_openai_api_key = ""
    SiteSetting.babel_reunited_anthropic_api_key = ""
    Fabricate(:post_translation, post: post_record, language: "es")

    expect {
      expect { task.invoke }.to output(/API key not configured/).to_stdout
    }.to raise_error(SystemExit)
    expect(dispatcher_jobs).to be_empty
  end

  it "still surveys the scale in a dry run without a provider" do
    SiteSetting.babel_reunited_openai_api_key = ""
    SiteSetting.babel_reunited_anthropic_api_key = ""
    Fabricate(:post_translation, post: post_record, language: "es")

    expect { task.invoke }.to output(/still needing detection: 1/).to_stdout
  end

  # Pacing above the allowance is not pacing: the jobs would arrive at a rate
  # the limiter refuses and burn their retries exactly as before.
  it "clamps PER_MINUTE to the site rate limit" do
    ENV["DRY_RUN"] = "false"
    SiteSetting.babel_reunited_rate_limit_per_minute = 2
    ENV["PER_MINUTE"] = "100"
    Fabricate(:post_translation, post: post_record, language: "es")

    expect { task.invoke }.to output(/using 2/).to_stdout
    expect(dispatcher_jobs.first["args"].first["per_minute"]).to eq(2)
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

  # Reporting one post and then handing the dispatcher the whole forum is the
  # opposite of the cautious first pass LIMIT exists for.
  it "passes LIMIT to the dispatcher on a live run" do
    ENV["DRY_RUN"] = "false"
    ENV["LIMIT"] = "1"
    Fabricate(:post_translation, post: post_record, language: "es")
    second = Fabricate(:post, topic: topic, user: user)
    Fabricate(:post_translation, post: second, language: "es")

    task.invoke

    expect(dispatcher_jobs.first["args"].first["remaining"]).to eq(1)
  end

  # The runbook asks for repeated runs to watch progress; each one starting
  # another chain would quietly multiply the rate.
  it "does not start a second dispatcher while one is running" do
    ENV["DRY_RUN"] = "false"
    Fabricate(:post_translation, post: post_record, language: "es")

    task.invoke
    expect(dispatcher_jobs.size).to eq(1)

    task.reenable
    expect { task.invoke }.to output(/already running/).to_stdout
    expect(dispatcher_jobs.size).to eq(1)
  end

  it "starts one again after the previous chain finished" do
    ENV["DRY_RUN"] = "false"
    Fabricate(:post_translation, post: post_record, language: "es")

    task.invoke
    BabelReunited.release_backfill_lease(
      Discourse.redis.get(BabelReunited.backfill_lease_key)
    )
    dispatcher_jobs.clear

    task.reenable
    expect { task.invoke }.to output(/Started the dispatcher/).to_stdout
    expect(dispatcher_jobs.size).to eq(1)
  end
end
