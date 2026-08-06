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
    ENV.delete("PER_MINUTE")
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

  # Detection shares one per-minute allowance with translation and the job
  # retries three times over about three minutes. Enqueued all at once, most
  # jobs burn those retries waiting for a slot and then die without a trace,
  # leaving the cleanup that follows just as blind as before.
  it "spreads the jobs out instead of dumping them into one minute" do
    ENV["DRY_RUN"] = "false"
    ENV["PER_MINUTE"] = "2"

    posts = 5.times.map { Fabricate(:post, topic: topic, user: user) }
    posts.each { |p| Fabricate(:post_translation, post: p, language: "es") }

    task.invoke

    delays =
      Jobs::BabelReunited::DetectPostLanguageJob
        .jobs
        .map { |j| j["at"].to_i }
        .sort
    # Five jobs at two per minute: three distinct scheduling slots.
    expect(delays.uniq.size).to be >= 3
    expect(delays.max - delays.min).to be >= 100
  end

  # A job that is scheduled but has not run yet has produced no locale, so a
  # re-run must still count that post as outstanding. Reporting it as done is
  # how an operator ends up running cleanup against posts that were never
  # detected -- the same silent failure the pacing exists to prevent.
  it "still counts a post whose job is only queued as needing detection" do
    ENV["DRY_RUN"] = "false"
    Fabricate(:post_translation, post: post_record, language: "es")

    task.invoke
    expect(Jobs::BabelReunited::DetectPostLanguageJob.jobs.size).to eq(1)

    task.reenable
    expect { task.invoke }.to output(
      /still needing detection: 1.*newly queued by this run: 0.*already queued by an earlier run: 1/m
    ).to_stdout
    expect(Jobs::BabelReunited::DetectPostLanguageJob.jobs.size).to eq(1)
  end

  it "reports nothing left once detection has actually landed" do
    ENV["DRY_RUN"] = "false"
    Fabricate(:post_translation, post: post_record, language: "es")
    BabelReunited.store_detected_locale(post_record, "en")

    expect { task.invoke }.to output(
      /still needing detection: 0.*Nothing left to detect/m
    ).to_stdout
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
    expect(Jobs::BabelReunited::DetectPostLanguageJob.jobs).to be_empty
  end

  # Two LIMIT batches must not both start their schedule at minute zero, or
  # the second lands on top of the first and doubles the rate.
  it "keeps pacing across separate runs" do
    ENV["DRY_RUN"] = "false"
    ENV["PER_MINUTE"] = "1"
    ENV["LIMIT"] = "1"

    first = Fabricate(:post, topic: topic, user: user)
    second = Fabricate(:post, topic: topic, user: user)
    [first, second].each do |p|
      Fabricate(:post_translation, post: p, language: "es")
    end

    task.invoke
    task.reenable
    task.invoke

    delays =
      Jobs::BabelReunited::DetectPostLanguageJob.jobs.map { |j| j["at"].to_i }
    expect(delays.size).to eq(2)
    expect(delays.uniq.size).to eq(2),
    "the second run reused the first run's slot"
  end

  # The cursor holds a time, not a running count. Once a schedule has been
  # consumed the allowance is idle again, so a later run must start from now
  # rather than from wherever the old count had reached -- otherwise a single
  # retry an hour later is pushed another hour out, and the task reports the
  # short span its own size implies.
  it "starts from now once the earlier schedule has been consumed" do
    ENV["DRY_RUN"] = "false"
    ENV["PER_MINUTE"] = "1"

    first = Fabricate(:post, topic: topic, user: user)
    second = Fabricate(:post, topic: topic, user: user)
    [first, second].each do |p|
      Fabricate(:post_translation, post: p, language: "es")
    end

    task.invoke
    expect(
      Jobs::BabelReunited::DetectPostLanguageJob.jobs.map { |j| j["at"].to_i }
    ).not_to be_empty

    # The whole schedule is in the past now, and the claims have lapsed.
    Discourse.redis.del(BabelReunited.backfill_cursor_key)
    [first, second].each do |p|
      Discourse.redis.del(BabelReunited.detection_backfill_key(p.id))
    end
    Jobs::BabelReunited::DetectPostLanguageJob.jobs.clear

    task.reenable
    task.invoke

    delays =
      Jobs::BabelReunited::DetectPostLanguageJob.jobs.map do |j|
        j["at"].to_i - Time.current.to_i
      end
    expect(delays.min).to be < 60
  end

  it "reports the span it actually scheduled, not the one its size implies" do
    ENV["DRY_RUN"] = "false"
    ENV["PER_MINUTE"] = "1"

    # Somebody else's schedule is already an hour deep.
    Discourse.redis.set(
      BabelReunited.backfill_cursor_key,
      Time.current.to_i + 3600
    )
    Fabricate(:post_translation, post: post_record, language: "es")

    expect { task.invoke }.to output(
      /the last one runs in ~6[0-9] minute\(s\)/
    ).to_stdout
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
