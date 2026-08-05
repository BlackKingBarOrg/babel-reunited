# frozen_string_literal: true

# The plugin replaces core's post-content-cooked-html wrapper outlet, so core
# regressions are a real risk; this exercises core basics with the plugin on.
RSpec.describe "Core features" do
  before do
    enable_current_plugin
    SiteSetting.babel_reunited_enabled = true

    # Core's shared examples use users without a language preference; the
    # preference modal would pop over the composer mid-test and intercept
    # clicks. Seed its once-per-browser flag so the flows stay deterministic.
    page.driver.with_playwright_page do |pw_page|
      pw_page.add_init_script(
        script:
          "window.localStorage.setItem('language_preference_modal_shown', 'true');"
      )
    end
  end

  it_behaves_like "having working core features"
end
