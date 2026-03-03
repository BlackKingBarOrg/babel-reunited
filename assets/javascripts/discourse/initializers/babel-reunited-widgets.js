import { withPluginApi } from "discourse/lib/plugin-api";
import LanguageTabsConnector from "../connectors/before-post-article/language-tabs";

/**
 * Initialize translation widgets and components
 * This initializer registers all translation-related widgets and components
 */
export default {
  name: "babel-reunited-widgets",

  initialize() {
    withPluginApi((api) => {
      api.renderInOutlet(
        "post-content-cooked-html",
        class extends LanguageTabsConnector {
          static shouldRender() {
            return true;
          }
        }
      );

      // Add translation components to post display
      api.addPostClassesCallback((attrs) => {
        if (attrs.show_translation_widget || attrs.show_translation_button) {
          return "has-translations";
        }
      });
    });
  },
};
