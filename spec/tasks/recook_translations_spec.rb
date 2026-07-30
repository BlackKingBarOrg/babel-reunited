# frozen_string_literal: true

RSpec.describe "babel_reunited:recook_translations" do
  fab!(:user)
  fab!(:topic) { Fabricate(:topic, user: user) }
  fab!(:post_record) { Fabricate(:post, topic: topic, user: user) }

  fab!(:translation) do
    BabelReunited::PostTranslation.create!(
      post_id: post_record.id,
      language: "zh-cn",
      status: "completed",
      source_language: "en",
      translated_raw: "**中文** 内容",
      translated_content: "<p>stale</p>"
    )
  end

  let(:task) { Rake::Task["babel_reunited:recook_translations"] }

  before do
    enable_current_plugin
    SiteSetting.babel_reunited_enabled = true
    task.reenable
  end

  after do
    ENV.delete("DRY_RUN")
    ENV.delete("VALIDATE")
  end

  it "defaults to a dry run that changes nothing" do
    BabelReunited::TranslatedCooker.expects(:call).never

    expect { task.invoke }.to output(/DRY RUN/).to_stdout
    expect(translation.reload.translated_content).to eq("<p>stale</p>")
  end

  it "recooks records when DRY_RUN=false" do
    ENV["DRY_RUN"] = "false"

    expect { task.invoke }.to output(/Processed:\s+1/).to_stdout
    expect(translation.reload.translated_content).to include(
      "<strong>中文</strong>"
    )
  end

  it "cooks without writing when VALIDATE=true" do
    ENV["VALIDATE"] = "true"

    expect { task.invoke }.to output(/Would change:\s+1/).to_stdout
    expect(translation.reload.translated_content).to eq("<p>stale</p>")
  end
end
