# frozen_string_literal: true

# The plugin replaces core's post-content-cooked-html wrapper outlet, so core
# regressions are a real risk; this exercises core basics with the plugin on.
RSpec.describe "Core features" do
  before do
    enable_current_plugin
    SiteSetting.babel_reunited_enabled = true
  end

  it_behaves_like "having working core features"
end
