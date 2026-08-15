import Component from "@glimmer/component";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { service } from "@ember/service";
// The ui-kit module path suggested by the lint rule is not resolvable in the
// plugin runtime yet; the legacy path works through core's compatibility shim.
// eslint-disable-next-line discourse/ui-kit-imports
import icon from "discourse/helpers/d-icon";
import { i18n } from "discourse-i18n";
import LanguagePreferenceModal from "./modal/language-preference";

// The reader's translation language otherwise lives on the account
// preferences page, which is somewhere nobody returns to. The modal that
// asks for it appears once, at first visit, and never again.
export default class BabelHeaderIcon extends Component {
  @service currentUser;
  @service modal;
  @service siteSettings;

  get shouldRender() {
    return this.siteSettings.babel_reunited_enabled && this.currentUser;
  }

  @action
  openLanguagePreference() {
    this.modal.show(LanguagePreferenceModal);
  }

  <template>
    {{#if this.shouldRender}}
      <li class="header-dropdown-toggle babel-language-toggle">
        <button
          type="button"
          class="icon btn-flat"
          title={{i18n "babel_reunited.header.language_preference"}}
          aria-label={{i18n "babel_reunited.header.language_preference"}}
          {{on "click" this.openLanguagePreference}}
        >
          {{icon "globe"}}
        </button>
      </li>
    {{/if}}
  </template>
}
