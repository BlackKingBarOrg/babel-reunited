# frozen_string_literal: true

RSpec.describe "babel_reunited:cleanup_same_language_copies" do
  fab!(:user)
  fab!(:topic) { Fabricate(:topic, user: user) }
  fab!(:post_record) { Fabricate(:post, topic: topic, user: user) }

  let(:task) { Rake::Task["babel_reunited:cleanup_same_language_copies"] }

  before do
    enable_current_plugin
    SiteSetting.babel_reunited_enabled = true
    task.reenable
  end

  after { ENV.delete("DRY_RUN") }

  it "defaults to a dry run that deletes nothing" do
    BabelReunited.store_detected_locale(post_record, "en")
    copy = Fabricate(:post_translation, post: post_record, language: "en")

    expect { task.invoke }.to output(/DRY RUN/).to_stdout
    expect(BabelReunited::PostTranslation.exists?(copy.id)).to be true
  end

  it "deletes only proven same-language copies when DRY_RUN=false" do
    ENV["DRY_RUN"] = "false"

    BabelReunited.store_detected_locale(post_record, "en")
    copy = Fabricate(:post_translation, post: post_record, language: "en")
    keeper = Fabricate(:post_translation, post: post_record, language: "es")

    undetected_post = Fabricate(:post, topic: topic, user: user)
    undetected_copy =
      Fabricate(:post_translation, post: undetected_post, language: "en")

    expect { task.invoke }.to output(/Deleted: 1 records/).to_stdout

    expect(BabelReunited::PostTranslation.exists?(copy.id)).to be false
    expect(BabelReunited::PostTranslation.exists?(keeper.id)).to be true
    expect(
      BabelReunited::PostTranslation.exists?(undetected_copy.id)
    ).to be true
  end

  it "keeps records whose post changed after the detection" do
    ENV["DRY_RUN"] = "false"

    # Detection says "en" but describes older content: the post may now be
    # written in another language, making the en translation the one needed.
    BabelReunited.store_detected_locale(post_record, "en", raw_sha: "0" * 64)
    needed = Fabricate(:post_translation, post: post_record, language: "en")

    expect { task.invoke }.to output(/Nothing to do/).to_stdout
    expect(BabelReunited::PostTranslation.exists?(needed.id)).to be true
  end
end
