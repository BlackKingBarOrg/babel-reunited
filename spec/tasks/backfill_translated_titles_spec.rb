# frozen_string_literal: true

RSpec.describe "babel_reunited:backfill_translated_titles" do
  fab!(:user)
  fab!(:topic) { Fabricate(:topic, user: user, title: "A translatable title") }
  fab!(:post_record) do
    Fabricate(:post, topic: topic, user: user, post_number: 1)
  end

  let(:task) { Rake::Task["babel_reunited:backfill_translated_titles"] }

  before do
    enable_current_plugin
    SiteSetting.babel_reunited_enabled = true
    task.reenable
  end

  after do
    ENV.delete("DRY_RUN")
    ENV.delete("LIMIT")
  end

  # Turning the setting on leaves existing bodies displayable, which is the
  # point -- but their status stays completed, so the view trigger passes
  # over them and the title they never had is never asked for.
  def translated_before_titles_were_on
    SiteSetting.babel_reunited_translate_title = false
    translation =
      Fabricate(
        :post_translation,
        post: post_record,
        language: "es",
        translated_title: nil
      )
    SiteSetting.babel_reunited_translate_title = true
    translation
  end

  it "defaults to a dry run that queues nothing" do
    translated_before_titles_were_on

    expect { task.invoke }.to output(/DRY RUN/).to_stdout
    expect(Jobs::BabelReunited::TranslatePostJob.jobs).to be_empty
  end

  it "queues a row that predates the setting" do
    translated_before_titles_were_on
    ENV["DRY_RUN"] = "false"

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

  # The body is good. Withdrawing it to add a title is a worse trade for the
  # reader than showing it with the original title for a while longer.
  it "leaves the body displayable while it waits" do
    translation = translated_before_titles_were_on
    ENV["DRY_RUN"] = "false"

    task.invoke

    expect(translation.reload.status).to eq("completed")
    expect(translation.safe_to_display?(post_record.reload)).to be true
  end

  it "ignores a row that already carries a title" do
    SiteSetting.babel_reunited_translate_title = true
    Fabricate(:post_translation, post: post_record, language: "es")

    expect { task.invoke }.to output(/Nothing to do/).to_stdout
  end

  it "ignores replies, which have no title of their own" do
    SiteSetting.babel_reunited_translate_title = false
    reply = Fabricate(:post, topic: topic, user: user, post_number: 2)
    Fabricate(
      :post_translation,
      post: reply,
      language: "es",
      translated_title: nil
    )
    SiteSetting.babel_reunited_translate_title = true

    expect { task.invoke }.to output(/Nothing to do/).to_stdout
  end

  it "does nothing at all while the setting is off" do
    SiteSetting.babel_reunited_translate_title = false
    ENV["DRY_RUN"] = "false"

    expect { task.invoke }.to output(/no titles to add/).to_stdout
    expect(Jobs::BabelReunited::TranslatePostJob.jobs).to be_empty
  end
end
