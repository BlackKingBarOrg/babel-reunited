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
end
