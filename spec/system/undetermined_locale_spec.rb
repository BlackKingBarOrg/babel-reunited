# frozen_string_literal: true

# Browser coverage for what PR #30 changed in front of a reader: a post the
# detector could not place must be indistinguishable from one never detected,
# and a detection that lands while a page is open must still correct it.
RSpec.describe "Detection results in the reading UI" do
  fab!(:admin)
  fab!(:topic)
  fab!(:post_record) do
    Fabricate(
      :post,
      topic: topic,
      post_number: 1,
      raw:
        "A post long enough to be detectable, used to check what a reader sees."
    )
  end

  before do
    enable_current_plugin
    SiteSetting.babel_reunited_enabled = true
    SiteSetting.babel_reunited_auto_translate_languages = "en,zh-cn,es"
    # Without a preference the language modal covers the page after a second.
    admin.custom_fields[BabelReunited::PREFERRED_LANGUAGE_FIELD] = "es"
    admin.save_custom_fields
    sign_in(admin)
  end

  def visit_topic
    visit "/t/#{topic.slug}/#{topic.id}"
    expect(page).to have_css("#post_1 .ai-language-tabs")
  end

  def tab_count
    all("#post_1 .babel-reunited-language-tab").size
  end

  def tab_labels
    all("#post_1 .babel-reunited-language-tab").map { |t| t.text.strip }
  end

  # A subscription is not live the moment it is registered: the client learns
  # its position on the first long poll, and anything published before that
  # poll completes is treated as already seen. Publishing into that window
  # looks exactly like a delivery failure.
  #
  # So prove the pipe end to end before relying on it: send something the
  # component ignores and wait for the client to actually reach it. Waiting on
  # the subscription merely existing is not enough -- last_id is set to 0 when
  # subscribe is called, before any poll has happened.
  def wait_for_live_subscription
    channel = "/post-translations/#{post_record.id}"
    MessageBus.publish(channel, { ping: true })
    target = MessageBus.last_id(channel)
    script =
      "(window.MessageBus?.callbacks ?? [])" \
        ".filter(c => c.channel === '#{channel}').map(c => c.last_id)"

    Timeout.timeout(30) do
      until page
              .evaluate_script(script)
              .any? { |i| i.is_a?(Integer) && i >= target }
        sleep 0.2
      end
    end
  end

  # The baseline the other two examples are measured against: nothing detected,
  # so every configured language is offered.
  it "offers every configured language when nothing is detected" do
    visit_topic

    expect(tab_count).to eq(5) # original + en + zh-cn + es + menu
  end

  # A real detection removes that language from the offer, because the original
  # tab already covers it. This is what makes the und case below meaningful --
  # without it, "und behaves like undetected" could pass by doing nothing.
  it "stops offering the language a post is written in" do
    BabelReunited.store_detected_locale(post_record, "en")

    visit_topic

    expect(tab_count).to eq(4)
    expect(tab_labels.join(" ")).not_to include("und")
  end

  # The new sentinel. It is recorded so the backfill can finish, but it is not
  # a language: the reader must be offered exactly what an undetected post
  # offers, and the string itself must never surface.
  it "renders an undetermined post exactly like an undetected one" do
    BabelReunited.store_detected_locale(
      post_record,
      BabelReunited::UNDETERMINED_LOCALE
    )

    visit_topic

    expect(tab_count).to eq(5)
    expect(tab_labels.join(" ")).not_to include("und")
    expect(page).to have_no_css(
      "#post_1 .babel-reunited-language-tab[title*='und']"
    )
  end

  # record_detected_locale publishes after the write. A page opened before
  # detection landed believes the language is unknown and offers to translate
  # the post into itself until this arrives.
  it "corrects an open page when a detection lands" do
    visit_topic
    expect(tab_count).to eq(5)
    wait_for_live_subscription

    sha = BabelReunited.detection_raw_sha(post_record)
    BabelReunited.record_detected_locale(post_record, "en", sha)

    # The en tab disappears without a reload. MessageBus delivery in a system
    # spec goes through a real long poll, so this needs more than the default.
    using_wait_time(20) do
      expect(page).to have_css("#post_1 .babel-reunited-language-tab", count: 4)
    end
  end

  # The undetermined answer is deliberately not published: there is nothing to
  # correct, and pushing it would only risk the string reaching a client.
  it "stays silent when an undetermined answer is recorded" do
    visit_topic
    expect(tab_count).to eq(5)
    wait_for_live_subscription

    sha = BabelReunited.detection_raw_sha(post_record)
    BabelReunited.record_detected_locale(
      post_record,
      BabelReunited::UNDETERMINED_LOCALE,
      sha
    )

    expect(page).to have_css("#post_1 .babel-reunited-language-tab", count: 5)
    expect(tab_labels.join(" ")).not_to include("und")
  end
end
