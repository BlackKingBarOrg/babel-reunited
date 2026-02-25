# frozen_string_literal: true

RSpec.describe BabelReunited::PostTranslation do
  fab!(:user)
  fab!(:topic) { Fabricate(:topic, user: user) }
  fab!(:post) { Fabricate(:post, topic: topic, user: user) }

  before { enable_current_plugin }

  def create_translation(content:, title: nil)
    BabelReunited::PostTranslation.create!(
      post: post,
      language: "en",
      translated_content: content,
      translated_title: title,
      status: "completed",
      translation_provider: "openai",
      metadata: {
      },
    )
  end

  describe "before_save sanitization of translated_content" do
    it "strips script tags" do
      t = create_translation(content: "<p>Hello</p><script>alert(1)</script>")
      expect(t.translated_content).not_to include("<script>")
      expect(t.translated_content).to include("<p>Hello</p>")
    end

    it "strips onerror attributes from img tags" do
      t = create_translation(content: "<img src=x onerror=alert(1)>")
      expect(t.translated_content).not_to include("onerror")
    end

    it "strips javascript: protocol from links" do
      t = create_translation(content: '<a href="javascript:alert(1)">click</a>')
      expect(t.translated_content).not_to include("javascript:")
    end

    it "strips onclick attributes" do
      t = create_translation(content: '<div onclick="alert(1)">text</div>')
      expect(t.translated_content).not_to include("onclick")
    end

    it "strips onmouseover attributes" do
      t = create_translation(content: '<span onmouseover="alert(1)">hover</span>')
      expect(t.translated_content).not_to include("onmouseover")
    end

    it "strips svg/onload injection" do
      t = create_translation(content: '<svg onload="alert(1)"><circle r="50"/></svg>')
      expect(t.translated_content).not_to include("onload")
    end

    it "preserves safe HTML formatting" do
      html =
        '<p>Hello <strong>world</strong></p><ul><li>item</li></ul><a href="https://example.com">link</a>'
      t = create_translation(content: html)
      expect(t.translated_content).to include("<p>")
      expect(t.translated_content).to include("<strong>world</strong>")
      expect(t.translated_content).to include("<ul>")
      expect(t.translated_content).to include("<li>item</li>")
      expect(t.translated_content).to include("https://example.com")
    end

    it "is idempotent — re-saving does not alter already-clean content" do
      t = create_translation(content: "<p>Hello <strong>world</strong></p>")
      original = t.translated_content
      t.save!
      expect(t.translated_content).to eq(original)
    end
  end

  describe "before_save sanitization of translated_title" do
    it "strips HTML tags from title" do
      t = create_translation(content: "<p>content</p>", title: "<script>alert(1)</script>")
      expect(t.translated_title).not_to include("<script>")
      expect(t.translated_title).to eq("alert(1)")
    end

    it "strips img tag with onerror from title" do
      t = create_translation(content: "<p>content</p>", title: "<img src=x onerror=alert(1)>")
      expect(t.translated_title).not_to include("<img")
    end

    it "preserves plain text titles" do
      t = create_translation(content: "<p>content</p>", title: "Hello World")
      expect(t.translated_title).to eq("Hello World")
    end

    it "is idempotent — re-saving does not alter already-clean title" do
      t = create_translation(content: "<p>content</p>", title: "Hello World")
      t.save!
      expect(t.translated_title).to eq("Hello World")
    end
  end
end
