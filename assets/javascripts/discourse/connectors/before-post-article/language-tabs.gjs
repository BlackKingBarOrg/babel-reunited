import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { htmlSafe } from "@ember/template";
import { eq } from "truth-helpers";
import icon from "discourse/helpers/d-icon";

/**
 * Simple language tabs connector component
 * Displays a basic language tabs box before each post
 */
export default class LanguageTabsConnector extends Component {
  // 统一的语言映射
  static languageMap = {
    en: "English",
    "zh-cn": "中文",
    es: "Español",
  };
  @service currentUser;
  @service messageBus;

  @tracked currentLanguage = "original";
  @tracked translationsVersion = 0; // 用于强制更新UI

  // 获取按钮样式 - 使用箭头函数保持this上下文
  getButtonStyle = (languageCode) => {
    // 读取 translationsVersion 以确保在翻译更新时重新计算
    this.translationsVersion;

    const baseStyle =
      "padding: 4px 16px; border-radius: 3px; cursor: pointer; font-size: 12px; height: 24px; line-height: 1;";

    // Original 按钮永远保持蓝色样式
    if (languageCode === "original") {
      if (this.currentLanguage === "original") {
        // 当前选中的 Original：蓝色背景，白色文字
        return htmlSafe(
          baseStyle +
            " background: #007bff; color: white; border: 1px solid #007bff;"
        );
      } else {
        // 未选中的 Original：白底，蓝字，蓝框
        return htmlSafe(
          baseStyle +
            " background: white; color: #007bff; border: 1px solid #007bff;"
        );
      }
    }

    // 获取翻译状态
    let status = "";
    if (this.post?.post_translations) {
      const translation = this.post.post_translations.find(
        (t) => t.post_translation?.language === languageCode
      );
      status = translation?.post_translation?.status || "";
    }

    let styleString;
    if (this.currentLanguage === languageCode) {
      // 当前选中的语言：蓝色背景，白色文字
      styleString =
        baseStyle +
        " background: #007bff; color: white; border: 1px solid #007bff;";
    } else if (status === "completed") {
      // 完成状态的翻译：白底，蓝字，蓝框
      styleString =
        baseStyle +
        " background: white; color: #007bff; border: 1px solid #007bff;";
    } else {
      // 其他所有状态：白底，灰字，灰框
      styleString =
        baseStyle +
        " background: white; color: #6c757d; border: 1px solid #6c757d; cursor: pointer; opacity: 0.8;";
    }

    return htmlSafe(styleString);
  };

  // 检查语言是否可用
  isLanguageAvailable = (languageCode) => {
    // 读取 translationsVersion 以确保在翻译更新时重新计算
    this.translationsVersion;

    if (languageCode === "original") {
      return true; // 原始内容总是可用的
    }
    const isAvailable = this.availableLanguages.includes(languageCode);
    return isAvailable;
  };

  constructor() {
    super(...arguments);

    // 自动选择用户的偏好语言
    this.initializePreferredLanguage();

    if (this.messageBus) {
      this.messageBus.subscribe(
        `/post-translations/${this.post.id}`,
        (data) => {
          // 更新 this.post 对象
          if (data.status === "completed" && data.translation) {
            this.updatePostTranslation(data.language, data.translation);
          }
        }
      );
    }
  }

  // 更新 post 对象的翻译数据
  updatePostTranslation(language, translationData) {
    if (!this.post.post_translations) {
      this.post.post_translations = [];
    }

    const existingIndex = this.post.post_translations.findIndex(
      (t) => t.post_translation?.language === language
    );

    if (existingIndex >= 0) {
      // 更新现有翻译
      this.post.post_translations[existingIndex].post_translation = {
        ...this.post.post_translations[existingIndex].post_translation,
        ...translationData,
      };
    } else {
      // 添加新翻译
      this.post.post_translations.push({
        post_translation: translationData,
      });
    }

    // 触发UI更新：增加版本号以通知所有依赖translationsVersion的getter重新计算
    this.translationsVersion++;
  }

  // 检查用户是否禁用了AI翻译功能
  get isAiTranslationDisabled() {
    return this.currentUser?.preferred_language_enabled === false;
  }

  /**
   * 初始化用户的偏好语言选择
   * 如果用户设置了偏好语言且该语言翻译已完成，则自动选择
   * 如果用户禁用了AI翻译功能，则不进行自动选择
   */
  initializePreferredLanguage() {
    // 如果用户禁用了AI翻译功能，直接使用原始内容
    if (this.isAiTranslationDisabled) {
      this.currentLanguage = "original";
      return;
    }

    if (!this.currentUser?.preferred_language) {
      return;
    }

    const preferredLanguage = this.currentUser.preferred_language;

    // 检查偏好语言的翻译状态
    let status = "";
    if (this.post?.post_translations) {
      const translation = this.post.post_translations.find(
        (t) => t.post_translation?.language === preferredLanguage
      );
      status = translation?.post_translation?.status || "";
    }

    // 只有当翻译状态是完成状态时才自动选择
    if (status === "completed") {
      this.currentLanguage = preferredLanguage;
    }
  }

  get post() {
    return this.args.post;
  }

  get availableLanguages() {
    // 读取 translationsVersion 以确保在翻译更新时重新计算
    this.translationsVersion;

    // 从 post_translations 获取已存在的翻译
    let languages = [];
    if (this.post?.post_translations) {
      languages = this.post.post_translations
        .map((t) => {
          return t.post_translation?.language;
        })
        .filter(Boolean);
    }

    return languages;
  }

  get languageNames() {
    // 读取 translationsVersion 以确保在翻译更新时重新计算
    this.translationsVersion;

    // 获取所有支持的语言（包括可用的和不可用的）
    const supportedLanguages = ["en", "zh-cn", "es"];

    const result = supportedLanguages.map((code) => {
      const name = LanguageTabsConnector.languageMap[code] || code;
      const available = this.isLanguageAvailable(code);

      // 获取翻译状态
      let status = "";
      if (this.post?.post_translations) {
        const translation = this.post.post_translations.find(
          (t) => t.post_translation?.language === code
        );
        status = translation?.post_translation?.status || "";
      }

      return {
        code,
        name,
        available,
        status,
        displayText:
          status && status !== "completed" ? `${name} (${status})` : name,
      };
    });

    return result;
  }

  // 获取当前显示的内容（HTML格式）
  get currentContent() {
    if (this.currentLanguage === "original") {
      return this.post?.cooked || this.post?.raw || "";
    }

    // 检查 post_translations 中的翻译
    let translation = null;
    if (this.post?.post_translations) {
      translation = this.post.post_translations.find(
        (t) => t.post_translation?.language === this.currentLanguage
      );
    }

    let translatedContent = "";
    if (translation?.post_translation?.translated_content) {
      translatedContent = translation.post_translation.translated_content;
    }

    if (translatedContent) {
      return translatedContent;
    }

    return this.post?.cooked || "";
  }

  // 获取当前语言名称
  get currentLanguageName() {
    if (this.currentLanguage === "original") {
      return "Original";
    }

    return (
      LanguageTabsConnector.languageMap[this.currentLanguage] ||
      this.currentLanguage
    );
  }

  // 切换语言的方法
  @action
  async switchLanguage(languageCode) {
    // 如果选择的是原始内容，直接切换
    if (languageCode === "original") {
      this.currentLanguage = languageCode;
      return;
    }

    // 获取翻译状态
    let status = "";
    if (this.post?.post_translations) {
      const translation = this.post.post_translations.find(
        (t) => t.post_translation?.language === languageCode
      );
      status = translation?.post_translation?.status || "";
    }

    // 如果翻译状态是完成状态，可以切换
    if (status === "completed") {
      this.currentLanguage = languageCode;
      return;
    }

    // 如果翻译状态不是完成状态，回退到原文 Original
    this.currentLanguage = "original";
  }

  // 新增：获取语言名称的辅助方法
  getLanguageName(languageCode) {
    return LanguageTabsConnector.languageMap[languageCode] || languageCode;
  }

  <template>
    {{! 只有在用户启用AI翻译功能时才显示语言切换标签 }}
    {{#if this.isAiTranslationDisabled}}
      <div
        style="font-size: 10px; color: #999; margin-bottom: 5px; margin-left: 12px;"
      >
        AI Translation is disabled by user
      </div>
    {{else}}
      <div
        class="ai-language-tabs"
        style="display: flex; gap: 3px; flex-wrap: wrap; margin-bottom: 8px; margin-left: 12px;"
      >
        <button
          style={{this.getButtonStyle "original"}}
          {{on "click" (fn this.switchLanguage "original")}}
        >
          Original
        </button>

        {{#each this.languageNames as |langInfo|}}
          <button
            style={{this.getButtonStyle langInfo.code}}
            {{on "click" (fn this.switchLanguage langInfo.code)}}
            title={{if
              langInfo.available
              "Switch to {{langInfo.name}}"
              "Click to start translation for {{langInfo.name}}"
            }}
          >
            {{langInfo.name}}
            {{#if (eq langInfo.status "translating")}}
              <span
                style="display: inline-block; animation: rotate-forever 1s infinite linear; margin-left: 4px;"
              >
                {{icon "spinner" class="loading-icon"}}
              </span>
            {{/if}}
          </button>
        {{/each}}
      </div>
    {{/if}}

    {{! 替换原post内容，直接显示当前选中的内容 }}
    <div class="cooked">
      {{htmlSafe this.currentContent}}
    </div>
  </template>
}
