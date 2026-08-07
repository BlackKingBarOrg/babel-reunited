# frozen_string_literal: true

RSpec.describe Jobs::BabelReunited::BackfillDetectionDispatcher do
  fab!(:user)
  fab!(:topic) { Fabricate(:topic, user: user) }

  before do
    enable_current_plugin
    SiteSetting.babel_reunited_enabled = true
    SiteSetting.babel_reunited_openai_api_key = "sk-test-key"
    SiteSetting.babel_reunited_preset_model = "gpt-4o"
    Discourse.redis.flushdb
    Jobs.run_later!
  end

  def post_needing_detection
    post = Fabricate(:post, topic: topic, user: user)
    Fabricate(:post_translation, post: post, language: "es")
    post
  end

  def detection_jobs
    Jobs::BabelReunited::DetectPostLanguageJob.jobs
  end

  # Every chain holds a lease; a job without one has been superseded.
  def run(per_minute:, token: nil, remaining: nil)
    token ||= BabelReunited.acquire_backfill_lease
    described_class.new.execute(
      per_minute: per_minute,
      lease_token: token,
      remaining: remaining
    )
    token
  end

  it "hands out at most per_minute detections per pass" do
    3.times { post_needing_detection }

    run(per_minute: 2)

    expect(detection_jobs.size).to eq(2)
  end

  it "re-arms itself a minute out while work remains" do
    2.times { post_needing_detection }

    run(per_minute: 1)

    follow_up = described_class.jobs.first
    expect(follow_up).to be_present
    expect(follow_up["args"].first["per_minute"]).to eq(1)
  end

  it "stops re-arming once nothing is left" do
    run(per_minute: 5)

    expect(described_class.jobs).to be_empty
  end

  # The reason this exists rather than scheduling every job up front: a
  # Sidekiq outage during the run would make every overdue job runnable at
  # once, and the burst dies against the rate limiter. Dispatching measures
  # the pace from when it actually runs, so lost time is lost time -- never
  # compressed into a flood.
  it "does not catch up after an outage" do
    5.times { post_needing_detection }

    # Three passes that "should" have happened during downtime never ran.
    # Whenever the dispatcher next runs, it still hands out only its share.
    run(per_minute: 1)

    expect(detection_jobs.size).to eq(1)
    expect(described_class.jobs.size).to eq(1)
  end

  it "asks for detection only, never a fan-out" do
    post_needing_detection

    run(per_minute: 5)

    expect(detection_jobs.first["args"].first["then_fanout"]).to be_falsey
    expect(Jobs::BabelReunited::TranslatePostJob.jobs).to be_empty
  end

  it "does not hand out the same post twice" do
    post_needing_detection

    # The same chain, twice: a fresh lease would be refused, and this is
    # about the per-post claim rather than the lease.
    token = run(per_minute: 5)
    run(per_minute: 5, token: token)

    expect(detection_jobs.size).to eq(1)
  end

  # LIMIT is the cautious first pass on a production run. Reporting a small
  # number and then processing everything is the opposite of cautious.
  it "carries the remaining LIMIT down the chain and stops at it" do
    3.times { post_needing_detection }

    run(per_minute: 5, remaining: 2)

    expect(detection_jobs.size).to eq(2)
    expect(described_class.jobs).to be_empty
  end

  it "keeps a multi-pass LIMIT shrinking rather than restarting" do
    4.times { post_needing_detection }

    token = run(per_minute: 1, remaining: 3)
    follow_up = described_class.jobs.first["args"].first
    expect(follow_up["remaining"]).to eq(2)

    described_class.jobs.clear
    described_class.new.execute(
      per_minute: 1,
      remaining: follow_up["remaining"],
      lease_token: token
    )
    expect(described_class.jobs.first["args"].first["remaining"]).to eq(1)
  end

  # A chain whose lease has gone is a chain that was replaced. Two chains
  # dispatching means twice the rate, which is the whole thing being paced.
  it "stops when it no longer holds the lease" do
    post_needing_detection

    described_class.new.execute(per_minute: 5, lease_token: "not-the-holder")

    expect(detection_jobs).to be_empty
    expect(described_class.jobs).to be_empty
  end

  it "releases the lease when it finishes, so the next run can start one" do
    token = run(per_minute: 5)

    expect(BabelReunited.backfill_lease_active?).to be false
    expect(BabelReunited.acquire_backfill_lease).to be_present
    expect(token).to be_present
  end

  # The chain may have started an hour ago; an admin lowering the allowance
  # means it now, not at the next backfill.
  it "re-reads the site limit every pass" do
    5.times { post_needing_detection }
    SiteSetting.babel_reunited_rate_limit_per_minute = 2

    run(per_minute: 30)

    expect(detection_jobs.size).to eq(2)
  end

  it "skips posts already detected against their current content" do
    post = post_needing_detection
    BabelReunited.store_detected_locale(post, "en")

    run(per_minute: 5)

    expect(detection_jobs).to be_empty
  end

  it "refuses to run without a configured provider" do
    post_needing_detection
    SiteSetting.babel_reunited_openai_api_key = ""
    SiteSetting.babel_reunited_anthropic_api_key = ""

    run(per_minute: 5)

    expect(detection_jobs).to be_empty
    expect(described_class.jobs).to be_empty
  end

  it "stops when the plugin is disabled" do
    post_needing_detection
    SiteSetting.babel_reunited_enabled = false

    run(per_minute: 5)

    expect(detection_jobs).to be_empty
    expect(described_class.jobs).to be_empty
  end
end
