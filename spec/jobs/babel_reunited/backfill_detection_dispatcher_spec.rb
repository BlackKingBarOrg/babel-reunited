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

  it "hands out at most per_minute detections per pass" do
    3.times { post_needing_detection }

    described_class.new.execute(per_minute: 2)

    expect(detection_jobs.size).to eq(2)
  end

  it "re-arms itself a minute out while work remains" do
    2.times { post_needing_detection }

    described_class.new.execute(per_minute: 1)

    follow_up = described_class.jobs.first
    expect(follow_up).to be_present
    expect(follow_up["args"].first["per_minute"]).to eq(1)
  end

  it "stops re-arming once nothing is left" do
    described_class.new.execute(per_minute: 5)

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
    described_class.new.execute(per_minute: 1)

    expect(detection_jobs.size).to eq(1)
    expect(described_class.jobs.size).to eq(1)
  end

  it "asks for detection only, never a fan-out" do
    post_needing_detection

    described_class.new.execute(per_minute: 5)

    expect(detection_jobs.first["args"].first["then_fanout"]).to be_falsey
    expect(Jobs::BabelReunited::TranslatePostJob.jobs).to be_empty
  end

  it "does not hand out the same post twice" do
    post_needing_detection

    described_class.new.execute(per_minute: 5)
    described_class.new.execute(per_minute: 5)

    expect(detection_jobs.size).to eq(1)
  end

  it "skips posts already detected against their current content" do
    post = post_needing_detection
    BabelReunited.store_detected_locale(post, "en")

    described_class.new.execute(per_minute: 5)

    expect(detection_jobs).to be_empty
  end

  it "refuses to run without a configured provider" do
    post_needing_detection
    SiteSetting.babel_reunited_openai_api_key = ""
    SiteSetting.babel_reunited_anthropic_api_key = ""

    described_class.new.execute(per_minute: 5)

    expect(detection_jobs).to be_empty
    expect(described_class.jobs).to be_empty
  end

  it "stops when the plugin is disabled" do
    post_needing_detection
    SiteSetting.babel_reunited_enabled = false

    described_class.new.execute(per_minute: 5)

    expect(detection_jobs).to be_empty
    expect(described_class.jobs).to be_empty
  end
end
