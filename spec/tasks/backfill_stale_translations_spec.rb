# frozen_string_literal: true

RSpec.describe "babel_reunited:backfill_stale_translations" do
  fab!(:user)
  fab!(:topic) { Fabricate(:topic, user: user) }
  fab!(:post_record) { Fabricate(:post, topic: topic, user: user) }

  let(:task) { Rake::Task["babel_reunited:backfill_stale_translations"] }

  before do
    enable_current_plugin
    SiteSetting.babel_reunited_enabled = true
    task.reenable
  end

  after do
    ENV.delete("DRY_RUN")
    ENV.delete("ENQUEUE")
    ENV.delete("LIMIT")
  end

  # A row written before edit-time invalidation existed: completed, and
  # carrying a body made from content the post no longer has.
  def outdated_translation(language: "es")
    translation =
      Fabricate(:post_translation, post: post_record, language: language)
    post_record.update_columns(raw: "The author rewrote this afterwards.")
    translation
  end

  it "defaults to a dry run that changes nothing" do
    translation = outdated_translation

    expect { task.invoke }.to output(/DRY RUN/).to_stdout
    expect(translation.reload.status).to eq("completed")
  end

  it "marks outdated rows stale and leaves current ones alone" do
    ENV["DRY_RUN"] = "false"

    current = Fabricate(:post_translation, post: post_record, language: "de")
    outdated = outdated_translation
    current.update_columns(
      source_sha:
        Jobs::BabelReunited::TranslatePostJob.content_sha(post_record.reload)
    )

    expect { task.invoke }.to output(/Marked stale:       1/).to_stdout

    expect(outdated.reload.status).to eq("stale")
    expect(current.reload.status).to eq("completed")
  end

  # trigger_retranslation already treats a missing fingerprint as outdated;
  # the sweep has to agree or the two disagree about the same row.
  it "treats a row with no fingerprint as outdated" do
    ENV["DRY_RUN"] = "false"

    translation =
      Fabricate(:post_translation, post: post_record, language: "es")
    translation.update_columns(source_sha: nil)

    task.invoke

    expect(translation.reload.status).to eq("stale")
  end

  it "queues re-translation only when asked" do
    ENV["DRY_RUN"] = "false"
    outdated_translation

    expect { task.invoke }.not_to change {
      Jobs::BabelReunited::TranslatePostJob.jobs.size
    }
  end

  it "queues a forced re-translation with ENQUEUE=true" do
    ENV["DRY_RUN"] = "false"
    ENV["ENQUEUE"] = "true"
    outdated_translation

    task.invoke

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

  # LIMIT bounds outdated rows, not rows looked at, and it has to actually
  # write them: an earlier version threw out of the batch before the update
  # ran, so the documented LIMIT=200 command reported findings and changed
  # nothing.
  describe "LIMIT" do
    it "marks exactly LIMIT rows and leaves the rest for the next run" do
      ENV["DRY_RUN"] = "false"
      ENV["LIMIT"] = "1"

      %w[es de fr].each do |lang|
        Fabricate(:post_translation, post: post_record, language: lang)
      end
      post_record.update_columns(raw: "The author rewrote this afterwards.")

      task.invoke

      statuses = BabelReunited::PostTranslation.group(:status).count
      expect(statuses["stale"]).to eq(1)
      expect(statuses["completed"]).to eq(2)
    end

    it "queues exactly the rows it marked" do
      ENV["DRY_RUN"] = "false"
      ENV["ENQUEUE"] = "true"
      ENV["LIMIT"] = "2"

      %w[es de fr].each do |lang|
        Fabricate(:post_translation, post: post_record, language: lang)
      end
      post_record.update_columns(raw: "The author rewrote this afterwards.")

      task.invoke

      expect(Jobs::BabelReunited::TranslatePostJob.jobs.size).to eq(2)
      expect(BabelReunited::PostTranslation.where(status: "stale").count).to eq(
        2
      )
    end

    # Bounding the scan instead of the findings meant a run whose first rows
    # were all current did nothing, and the next run read them again.
    it "keeps scanning past current rows to reach an outdated one" do
      ENV["DRY_RUN"] = "false"
      ENV["LIMIT"] = "1"
      ENV["BATCH_SIZE"] = "2"

      other = Fabricate(:post, topic: topic, user: user)
      4.times do |i|
        Fabricate(:post_translation, post: other, language: %w[es de fr it][i])
      end
      outdated = Fabricate(:post_translation, post: post_record, language: "es")
      post_record.update_columns(raw: "Only this post was rewritten.")

      task.invoke

      expect(outdated.reload.status).to eq("stale")
    end
  end

  # A translation finishing between the read and the write carries a new
  # fingerprint; overwriting it by id would discard correct, just-completed
  # work and pay a provider to redo it.
  it "does not clobber a translation that completed mid-run" do
    ENV["DRY_RUN"] = "false"

    translation = outdated_translation
    fresh_sha =
      Jobs::BabelReunited::TranslatePostJob.content_sha(post_record.reload)

    # The row is read as outdated, and the job lands before the write. The
    # hook stands exactly in that gap: it updates the row the way a finishing
    # job would, then reports the fingerprint as not matching so the sweep
    # goes on to try the write it must not make.
    landed = false
    BabelReunited.singleton_class.send(
      :alias_method,
      :orig_variants,
      :content_sha_variants_for
    )
    BabelReunited.define_singleton_method(:content_sha_variants_for) do |post|
      unless landed
        landed = true
        translation.update_columns(source_sha: fresh_sha)
      end
      ["a fingerprint the row does not carry"]
    end

    begin
      task.invoke
    ensure
      BabelReunited.singleton_class.send(
        :alias_method,
        :content_sha_variants_for,
        :orig_variants
      )
    end

    expect(landed).to be true
    expect(translation.reload.status).to eq("completed")
    expect(translation.source_sha).to eq(fresh_sha)
  end

  it "reports nothing to do when every fingerprint still matches" do
    Fabricate(:post_translation, post: post_record, language: "es")

    expect { task.invoke }.to output(/Nothing to do/).to_stdout
  end
end
