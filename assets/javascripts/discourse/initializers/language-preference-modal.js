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
      const siteSettings = api.container.lookup("service:site-settings");
      const router = api.container.lookup("service:router");
      if (!modal || !messageBus || !siteSettings || !router) {
        return;
      }

      let pendingModalTimeoutId = null;

      const isInEnabledCategory = () => {
        const enabledCategories =
          siteSettings.babel_reunited_enabled_categories;
        if (!enabledCategories) {
          return true;
        }

        const allowedIds = enabledCategories.split("|").map(Number);
        let route = router.currentRoute;
        while (route) {
          const attrs = route.attributes;
          if (attrs) {
            if (attrs.category?.id !== undefined) {
              return allowedIds.includes(attrs.category.id);
            }
            if (attrs.category_id !== undefined) {
              return allowedIds.includes(attrs.category_id);
            }
          }
          route = route.parent;
        }
        return false;
      };

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

        if (!isInEnabledCategory()) {
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
