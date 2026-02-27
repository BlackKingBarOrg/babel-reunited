import { withPluginApi } from "discourse/lib/plugin-api";
import LanguagePreferenceModal from "discourse/plugins/babel-reunited/discourse/components/modal/language-preference";

export default {
  initialize() {
    withPluginApi((api) => {
      const currentUser = api.getCurrentUser();
      if (!currentUser) {
        return;
      }

      const modal = api.container.lookup("service:modal");
      const messageBus = api.container.lookup("service:message-bus");
      if (!modal || !messageBus) {
        return;
      }

      let pendingModalTimeoutId = null;

      const scheduleModalShow = () => {
        if (
          currentUser.preferred_language_enabled === false ||
          currentUser.preferred_language
        ) {
          return;
        }

        if (localStorage.getItem("language_preference_modal_shown")) {
          return;
        }

        if (pendingModalTimeoutId) {
          clearTimeout(pendingModalTimeoutId);
        }

        pendingModalTimeoutId = setTimeout(() => {
          modal.show(LanguagePreferenceModal);
          pendingModalTimeoutId = null;
        }, 1000);
      };

      // 1. Subscribe to MessageBus only once
      messageBus.subscribe(
        `/language-preference-prompt/${currentUser.id}`,
        () => {
          scheduleModalShow();
        }
      );

      // 2. Also check on initial page load or page changes
      api.onPageChange(() => {
        if (pendingModalTimeoutId) {
          clearTimeout(pendingModalTimeoutId);
          pendingModalTimeoutId = null;
        }

        scheduleModalShow();
      });
    });
  },
};
