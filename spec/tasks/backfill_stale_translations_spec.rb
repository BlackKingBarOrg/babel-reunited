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

  it "bounds the sweep with LIMIT" do
    ENV["DRY_RUN"] = "false"
    ENV["LIMIT"] = "1"

    Fabricate(:post_translation, post: post_record, language: "es")
    Fabricate(:post_translation, post: post_record, language: "de")
    post_record.update_columns(raw: "The author rewrote this afterwards.")

    expect { task.invoke }.to output(/Scanned:            1/).to_stdout
  end

  it "reports nothing to do when every fingerprint still matches" do
    Fabricate(:post_translation, post: post_record, language: "es")

    expect { task.invoke }.to output(/Nothing to do/).to_stdout
  end
end
