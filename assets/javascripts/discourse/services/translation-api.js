import Service from "@ember/service";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { disableImplicitInjections } from "discourse/lib/implicit-injections";

/**
 * Translation API service for handling translation-related API calls
 */
@disableImplicitInjections
export default class TranslationApiService extends Service {
  /**
   * Get all translations for a post
   * @param {number} postId - The post ID
   * @returns {Promise<Array>} Array of translation objects
   */
  async getTranslations(postId) {
    try {
      const result = await ajax(`/ai-translator/posts/${postId}/translations`);
      return result.translations || [];
    } catch (error) {
      popupAjaxError(error);
      throw error;
    }
  }

  /**
   * Get a specific translation for a post
   * @param {number} postId - The post ID
   * @param {string} language - The language code
   * @returns {Promise<Object>} Translation object
   */
  async getTranslation(postId, language) {
    try {
      const result = await ajax(`/ai-translator/posts/${postId}/translations/${language}`);
      return result.translation;
    } catch (error) {
      popupAjaxError(error);
      throw error;
    }
  }

  /**
   * Create a new translation for a post
   * @param {number} postId - The post ID
   * @param {string} targetLanguage - The target language code
   * @param {boolean} forceUpdate - Whether to force update existing translation
   * @returns {Promise<Object>} Translation result
   */
  async createTranslation(postId, targetLanguage, forceUpdate = false) {
    try {
      const result = await ajax(`/ai-translator/posts/${postId}/translations`, {
        type: "POST",
        data: { 
          target_language: targetLanguage,
          force_update: forceUpdate
        }
      });
      return result;
    } catch (error) {
      popupAjaxError(error);
      throw error;
    }
  }

  /**
   * Delete a translation for a post
   * @param {number} postId - The post ID
   * @param {string} language - The language code
   * @returns {Promise<Object>} Deletion result
   */
  async deleteTranslation(postId, language) {
    try {
      const result = await ajax(`/ai-translator/posts/${postId}/translations/${language}`, {
        type: "DELETE"
      });
      return result;
    } catch (error) {
      popupAjaxError(error);
      throw error;
    }
  }

  /**
   * Batch translate multiple posts
   * @param {Array<number>} postIds - Array of post IDs
   * @param {Array<string>} targetLanguages - Array of target language codes
   * @returns {Promise<Object>} Batch translation result
   */
  async batchTranslate(postIds, targetLanguages) {
    try {
      const result = await ajax("/ai-translator/batch-translate", {
        type: "POST",
        data: { 
          post_ids: postIds,
          target_languages: targetLanguages
        }
      });
      return result;
    } catch (error) {
      popupAjaxError(error);
      throw error;
    }
  }

  /**
   * Get translation statistics
   * @returns {Promise<Object>} Translation statistics
   */
  async getTranslationStats() {
    try {
      const result = await ajax("/ai-translator/stats");
      return result;
    } catch (error) {
      popupAjaxError(error);
      throw error;
    }
  }

  /**
   * Get supported languages
   * @returns {Promise<Array>} Array of supported language objects
   */
  async getSupportedLanguages() {
    try {
      const result = await ajax("/ai-translator/languages");
      return result.languages || [];
    } catch (error) {
      popupAjaxError(error);
      throw error;
    }
  }

  /**
   * Detect language of a text
   * @param {string} text - The text to detect language for
   * @returns {Promise<Object>} Language detection result
   */
  async detectLanguage(text) {
    try {
      const result = await ajax("/ai-translator/detect-language", {
        type: "POST",
        data: { text }
      });
      return result;
    } catch (error) {
      popupAjaxError(error);
      throw error;
    }
  }

  /**
   * Get translation status for a post
   * @param {number} postId - The post ID
   * @returns {Promise<Object>} Translation status including pending and available translations
   */
  async getTranslationStatus(postId) {
    try {
      const result = await ajax(`/ai-translator/posts/${postId}/translations/translation_status`);
      return result;
    } catch (error) {
      popupAjaxError(error);
      throw error;
    }
  }
}

