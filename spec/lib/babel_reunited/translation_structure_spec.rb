# frozen_string_literal: true

RSpec.describe BabelReunited::TranslationStructure do
  before { enable_current_plugin }

  PROPOSAL = <<~MD
    ## 1. Overview

    A proposal with structure.

    - first point
    - second point
    - third point
    - fourth point

    ```ruby
    def code
    end
    ```

    > a quoted line

    Closing paragraph with enough length to enable the ratio check. #{"x" * 200}
  MD

  it "reports no drift for a faithful translation (structure preserved)" do
    translated = PROPOSAL.gsub("point", "punto").gsub("Overview", "Resumen")
    expect(described_class.drift(PROPOSAL, translated)).to be_empty
  end

  it "reports no drift for verbatim same-language output" do
    expect(described_class.drift(PROPOSAL, PROPOSAL.dup)).to be_empty
  end

  it "tolerates small structural wobble" do
    # One merged list item: within absolute tolerance
    translated = PROPOSAL.sub("- first point\n", "")
    expect(described_class.drift(PROPOSAL, translated)).to be_empty
  end

  it "tolerates wide length ratios between languages" do
    # CJK translations legitimately halve the character count
    translated = PROPOSAL[0, PROPOSAL.length / 2]
    drift = described_class.drift(PROPOSAL, translated)
    expect(drift.grep(/length ratio/)).to be_empty
  end

  it "skips the length check for short texts" do
    expect(
      described_class.drift("short", "a much longer output " * 10)
    ).to be_empty
  end

  it "flags answer-mode output that replaced the source's structure" do
    questions = <<~MD
      几个问题想请你直接回答：

      1. 这个需求你是怎么发现的？
      2. 你自己实际集成过吗？
      3. 安全性上牺牲了什么？

      #{"补充说明。" * 30}
    MD

    answers = <<~MD
      感谢你的直接提问，我也直接回答。

      ## 1. 这个需求是怎么发现的？

      坦白说：主要是分析出来的。#{"详细解释。" * 20}

      ## 2. 是否实际集成过？

      没有。#{"详细解释。" * 20}

      ## 3. 安全性权衡

      - 基线分析
      - 我的方案牺牲了什么
      - 如何补偿
      - 泄露场景一
      - 泄露场景二
      - 泄露场景三

      #{"进一步展开。" * 40}
    MD

    drift = described_class.drift(questions, answers)
    expect(drift).not_to be_empty
  end

  it "flags output that dropped all structure" do
    flattened = "One long paragraph. #{"словами " * 120}"
    drift = described_class.drift(PROPOSAL, flattened)
    expect(drift).not_to be_empty
  end

  # The scan flagged 53 records on staging and only 3 were real. Each block
  # below is one of the three causes, with the shapes that produced them.
  describe "false positives the staging sweep exposed" do
    it "allows the expansion Chinese to Latin actually produces" do
      chinese = "#{"这是一段中文说明文字。" * 30}"
      # Every flagged over-ratio sat between 4.01 and 4.82.
      english = "a" * (chinese.gsub(/\s+/, " ").strip.length * 45 / 10)

      expect(described_class.drift(chinese, english)).to be_empty
    end

    it "allows the compression Latin to Chinese actually produces" do
      english = "This is a sentence of English prose. " * 40
      chinese = "中文说明。" * (english.length / 45)

      expect(described_class.drift(english, chinese)).to be_empty
    end

    # Post 23994 carried long runs of padding, which inflated the original's
    # length and pushed a faithful translation to a ratio of 0.19.
    it "does not let padding in the source inflate its length" do
      padded = "#{"Real prose that carries the meaning. " * 10}#{"\n" * 4000}"
      translated = "Prosa real que transmite el significado. " * 10

      expect(described_class.drift(padded, translated)).to be_empty
    end

    # About 19 of the 53 looked like "headings 54->27, list_items 304->152":
    # the author wrote the same document twice, once per language, and the
    # translation produces one of them.
    it "reads a bilingual original as two documents, not a truncation" do
      chinese_half = <<~MD
        ## 第一节

        - 第一点
        - 第二点
        - 第三点
        - 第四点
        - 第五点
        - 第六点

        #{"中文正文说明文字。" * 40}
      MD
      english_half = <<~MD
        ## Section One

        - First point
        - Second point
        - Third point
        - Fourth point
        - Fifth point
        - Sixth point

        #{"English body prose explaining the same thing. " * 20}
      MD

      expect(
        described_class.drift(chinese_half + english_half, english_half)
      ).to be_empty
    end

    # The same halving from a monolingual source is truncation, and the
    # scripts are what tell the two apart.
    it "still flags a monolingual source that lost half its structure" do
      section_one = <<~MD
        ## Section One

        - First point
        - Second point
        - Third point
        - Fourth point
        - Fifth point
        - Sixth point

        #{"English body prose explaining the same thing. " * 20}
      MD
      section_two = <<~MD
        ## Section Two

        - Seventh point
        - Eighth point
        - Ninth point
        - Tenth point
        - Eleventh point
        - Twelfth point

        #{"More English body prose explaining the second half. " * 20}
      MD

      expect(
        described_class.drift(section_one + section_two, section_one)
      ).not_to be_empty
    end

    # Post 25041 wrote "1.演示视频" with no space, so the original counted 0
    # list items and its translation counted 3.
    it "counts a CJK list marker written without a space" do
      source = <<~MD
        1.演示视频
        2.技术说明
        3.后续计划

        #{"补充说明的正文内容。" * 40}
      MD
      translated = <<~MD
        1. Demo video
        2. Technical notes
        3. Next steps

        #{"Body prose that expands on each of the three points above. " * 15}
      MD

      expect(described_class.signature(source)[:list_items]).to eq(3)
      expect(described_class.drift(source, translated)).to be_empty
    end

    it "does not read a decimal as a list marker" do
      signature = described_class.signature("1.5 million users\n")
      expect(signature[:list_items]).to eq(0)
    end

    # The allowance is for numeric markers only. A bullet run straight into
    # CJK is an italic line far more often than a list item, and counting it
    # invents structure on the translated side of every emphasised paragraph.
    it "does not read CJK emphasis as a list marker" do
      signature = described_class.signature("*说得很准确，这正是差距所在。*\n")
      expect(signature[:list_items]).to eq(0)
    end
  end
end
