import { registerDestructor } from "@ember/destroyable";
import { cancel } from "@ember/runloop";
import Modifier from "ember-modifier";
import discourseLater from "discourse/lib/later";

// Fires once the element has been continuously visible for `dwellMs`.
//
// Component construction is not "the reader saw this": the post stream
// uncloaks a full viewport height beyond the visible area, so a connector can
// be built for posts well below the fold. Only real intersection, held long
// enough that a scroll-past does not count, means the post was read.
export default class BabelViewDwell extends Modifier {
  #observer = null;
  #timer = null;
  #fired = false;

  constructor(owner, args) {
    super(owner, args);
    registerDestructor(this, () => this.#teardown());
  }

  modify(element, [callback], { dwellMs = 500 } = {}) {
    if (this.#fired || this.#observer) {
      return;
    }

    this.#observer = new IntersectionObserver(
      (entries) => {
        const visible = entries.some((entry) => entry.isIntersecting);

        if (!visible) {
          this.#clearTimer();
          return;
        }

        this.#timer ||= discourseLater(() => {
          this.#fired = true;
          this.#teardown();
          callback();
        }, dwellMs);
      },
      { threshold: 0 }
    );

    this.#observer.observe(element);
  }

  #clearTimer() {
    cancel(this.#timer);
    this.#timer = null;
  }

  #teardown() {
    this.#clearTimer();
    this.#observer?.disconnect();
    this.#observer = null;
  }
}
