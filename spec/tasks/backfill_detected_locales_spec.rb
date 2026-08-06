# frozen_string_literal: true

RSpec.describe "babel_reunited:backfill_detected_locales" do
  fab!(:user)
  fab!(:topic) { Fabricate(:topic, user: user) }
  fab!(:post_record) { Fabricate(:post, topic: topic, user: user) }

  let(:task) { Rake::Task["babel_reunited:backfill_detected_locales"] }

  before do
    enable_current_plugin
    SiteSetting.babel_reunited_enabled = true
    Discourse.redis.flushdb
    Jobs.run_later!
    task.reenable
  end

  after do
    ENV.delete("DRY_RUN")
    ENV.delete("LIMIT")
  end

  it "defaults to a dry run that enqueues nothing" do
    Fabricate(:post_translation, post: post_record, language: "es")

    expect { task.invoke }.to output(/DRY RUN/).to_stdout
    expect(Jobs::BabelReunited::DetectPostLanguageJob.jobs).to be_empty
  end

  it "enqueues detection for a post whose translations predate detection" do
    ENV["DRY_RUN"] = "false"
    Fabricate(:post_translation, post: post_record, language: "es")

    task.invoke

    expect(
      job_enqueued?(
        job: Jobs::BabelReunited::DetectPostLanguageJob,
        args: {
          post_id: post_record.id
        }
      )
    ).to be true
  end

  # The whole point of the backfill is to make cleanup_same_language_copies
  # able to see these posts; asking for a fan-out here would start a
  # translation for every language on every legacy post instead.
  it "asks for detection only, never a fan-out" do
    ENV["DRY_RUN"] = "false"
    Fabricate(:post_translation, post: post_record, language: "es")

    task.invoke

    args = Jobs::BabelReunited::DetectPostLanguageJob.jobs.first["args"].first
    expect(args["then_fanout"]).to be_falsey
    expect(Jobs::BabelReunited::TranslatePostJob.jobs).to be_empty
  end

  it "skips a post already detected against its current content" do
    ENV["DRY_RUN"] = "false"
    Fabricate(:post_translation, post: post_record, language: "es")
    BabelReunited.store_detected_locale(post_record, "en")

    expect { task.invoke }.to output(/needing detection: 0/).to_stdout
    expect(Jobs::BabelReunited::DetectPostLanguageJob.jobs).to be_empty
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
    expect(Jobs::BabelReunited::DetectPostLanguageJob.jobs).to be_empty
  end

  it "honors LIMIT so a first pass can be sized" do
    ENV["DRY_RUN"] = "false"
    ENV["LIMIT"] = "1"
    Fabricate(:post_translation, post: post_record, language: "es")
    second = Fabricate(:post, topic: topic, user: user)
    Fabricate(:post_translation, post: second, language: "es")

    task.invoke

    expect(Jobs::BabelReunited::DetectPostLanguageJob.jobs.size).to eq(1)
  end
end
