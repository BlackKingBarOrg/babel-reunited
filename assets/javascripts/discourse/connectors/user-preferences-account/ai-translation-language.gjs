import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { service } from "@ember/service";
import concatClass from "discourse/helpers/concat-class";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { eq } from "discourse/truth-helpers";
import { i18n } from "discourse-i18n";
import { getSupportedLanguages } from "../../lib/supported-languages";

export default class AiTranslationLanguage extends Component {
  static shouldRender(args, context) {
    return context.siteSettings.babel_reunited_enabled;
  }

  @service currentUser;
  @service siteSettings;

  @tracked saving = false;
  @tracked currentLanguage = null;
  @tracked enabled = true;
  @tracked showSavedNotice = false;

  savedNoticeTimerId = null;

  constructor() {
    super(...arguments);
    this.loadCurrentLanguage();
  }

  willDestroy() {
    super.willDestroy?.();
    if (this.savedNoticeTimerId) {
      clearTimeout(this.savedNoticeTimerId);
      this.savedNoticeTimerId = null;
    }
  }

  async loadCurrentLanguage() {
    try {
      const response = await ajax("/babel-reunited/user-preferred-language", {
        type: "GET",
      });
      this.currentLanguage = response.language || null;
      this.enabled = response.enabled !== false;
    } catch {
      this.currentLanguage = null;
      this.enabled = true;
    }
  }

  showSaved() {
    this.showSavedNotice = true;
    if (this.savedNoticeTimerId) {
      clearTimeout(this.savedNoticeTimerId);
    }
    this.savedNoticeTimerId = setTimeout(() => {
      this.showSavedNotice = false;
      this.savedNoticeTimerId = null;
    }, 2000);
  }

  get languageOptions() {
    return getSupportedLanguages(this.siteSettings).map((code) => ({
      value: code,
      label: i18n(`babel_reunited.language_tabs.languages.${code}`, {
        defaultValue: code,
      }),
    }));
  }

  @action
  async changeLanguage(language) {
    this.saving = true;

    try {
      await ajax("/babel-reunited/user-preferred-language", {
        type: "POST",
        data: { language, enabled: this.enabled },
      });

      this.currentLanguage = language;
      this.showSaved();

      if (this.currentUser) {
        this.currentUser.set("preferred_language", language);
        this.currentUser.set("preferred_language_enabled", this.enabled);
      }
    } catch (error) {
      popupAjaxError(error);
    } finally {
      this.saving = false;
    }
  }

  @action
  async toggleEnabled() {
    this.saving = true;

    try {
      const newEnabled = !this.enabled;
      await ajax("/babel-reunited/user-preferred-language", {
        type: "POST",
        data: { enabled: newEnabled },
      });

      this.enabled = newEnabled;
      this.showSaved();

      if (this.currentUser) {
        this.currentUser.set("preferred_language_enabled", newEnabled);
      }
    } catch (error) {
      popupAjaxError(error);
    } finally {
      this.saving = false;
    }
  }

  <template>
    <div class="control-group ai-translation-language">
      <label class="control-label">
        {{i18n "babel_reunited.preferences.ai_translation_language"}}
        <span
          class={{concatClass
            "saved-notice"
            (if this.showSavedNotice "--visible")
          }}
          aria-live="polite"
        >
          {{i18n "saved"}}
        </span>
      </label>

      <div class="controls">
        <div class="ai-translation-toggle">
          <label class="toggle-label">
            <input
              type="checkbox"
              checked={{this.enabled}}
              disabled={{this.saving}}
              {{on "change" this.toggleEnabled}}
              class="toggle-checkbox"
            />
            <span class="toggle-slider"></span>
            <span class="toggle-text">
              {{i18n "babel_reunited.preferences.enable_ai_translation"}}
            </span>
          </label>
        </div>
      </div>

      {{#if this.enabled}}
        <div class="controls">
          <div class="language-selection">
            {{#each this.languageOptions as |option|}}
              <button
                type="button"
                class={{concatClass
                  "language-option btn btn-small"
                  (if
                    (eq option.value this.currentLanguage)
                    "btn-primary --selected"
                  )
                }}
                disabled={{this.saving}}
                {{on "click" (fn this.changeLanguage option.value)}}
                aria-pressed={{if
                  (eq option.value this.currentLanguage)
                  "true"
                  "false"
                }}
              >
                {{option.label}}
              </button>
            {{/each}}
          </div>
        </div>
      {{/if}}

      <div class="instructions">
        {{i18n
          "babel_reunited.preferences.ai_translation_language_description"
        }}
      </div>
    </div>
  </template>
}
