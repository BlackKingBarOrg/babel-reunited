import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { service } from "@ember/service";
import DModal from "discourse/components/d-modal";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { i18n } from "discourse-i18n";

export default class LanguagePreferenceModal extends Component {
  @service currentUser;
  @service modal;

  @tracked saving = false;

  @action
  async selectLanguage(language) {
    this.saving = true;

    try {
      await ajax("/babel-reunited/user-preferred-language", {
        type: "POST",
        data: { language },
      });

      this.currentUser.set("preferred_language", language);
      this.currentUser.set("preferred_language_enabled", true);
      localStorage.setItem("language_preference_modal_shown", "true");
      this.modal.close();
    } catch (error) {
      popupAjaxError(error);
    } finally {
      this.saving = false;
    }
  }

  @action
  async disableTranslation() {
    this.saving = true;

    try {
      await ajax("/babel-reunited/user-preferred-language", {
        type: "POST",
        data: { enabled: false },
      });

      this.currentUser.set("preferred_language_enabled", false);
      localStorage.setItem("language_preference_modal_shown", "true");
      this.modal.close();
    } catch (error) {
      popupAjaxError(error);
    } finally {
      this.saving = false;
    }
  }

  @action
  skip() {
    localStorage.setItem("language_preference_modal_shown", "true");
    this.modal.close();
  }

  <template>
    <DModal
      @closeModal={{@closeModal}}
      @title={{i18n "js.babel_reunited.language_preference_modal.title"}}
      class="language-preference-modal"
    >
      <:body>
        <p>{{i18n
            "js.babel_reunited.language_preference_modal.description"
          }}</p>

        <div class="language-buttons">
          <button
            class="language-btn language-btn-en"
            disabled={{this.saving}}
            {{on "click" (fn this.selectLanguage "en")}}
          >
            <span class="flag">🇺🇸</span>
            <span class="language-name">English</span>
          </button>
          <button
            class="language-btn language-btn-zh-cn"
            disabled={{this.saving}}
            {{on "click" (fn this.selectLanguage "zh-cn")}}
          >
            <span class="flag">🇨🇳</span>
            <span class="language-name">中文</span>
          </button>
          <button
            class="language-btn language-btn-es"
            disabled={{this.saving}}
            {{on "click" (fn this.selectLanguage "es")}}
          >
            <span class="flag">🇪🇸</span>
            <span class="language-name">Español</span>
          </button>
        </div>

        <div class="disable-section">
          <div class="disable-text">
            {{i18n
              "js.babel_reunited.language_preference_modal.disable_description"
            }}
          </div>
          <button
            class="disable-btn"
            disabled={{this.saving}}
            {{on "click" this.disableTranslation}}
          >
            <span class="disable-icon">🚫</span>
            <span class="disable-label">{{i18n
                "js.babel_reunited.language_preference_modal.disable"
              }}</span>
          </button>
        </div>
      </:body>
    </DModal>
  </template>
}
