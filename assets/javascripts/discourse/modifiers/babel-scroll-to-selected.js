import { schedule } from "@ember/runloop";
import Modifier from "ember-modifier";

// How much of the list to leave above the selection, so the group heading it
// belongs to stays visible: seeing which group your language is in is the
// point of scrolling to it at all.
const SLACK_PX = 60;

// Frames the position must hold before the alignment is considered done, and
// the ceiling on how long it may keep trying.
const STABLE_FRAMES = 3;
const MAX_FRAMES = 60;

// Opens a long list on the current selection instead of at the top.
//
// The language list runs to a hundred rows in a box that shows about ten, so
// a reader whose language sits in the on-demand group has no way to see what
// they picked, or that it is the slow kind.
export default class BabelScrollToSelected extends Modifier {
  #aligned = false;

  modify(container, [selectedCode]) {
    if (this.#aligned || !selectedCode) {
      return;
    }

    this.#aligned = true;
    schedule("afterRender", () => this.#align(container));
  }

  // Re-aligned until the position holds still, rather than measured once.
  // The list is a hundred rows of Arabic, Devanagari, Thai, CJK and more:
  // their webfonts land over several frames after first paint, and each one
  // changes the height of the rows above the selection. A single measurement
  // is taken against a list that is still growing, and the browser clamps the
  // scroll to a height that no longer exists moments later.
  #align(container) {
    let frames = 0;
    let stable = 0;
    let stopped = false;

    // Whatever the fonts are doing, the reader wins: the first flick of the
    // wheel ends the correction rather than fighting it.
    const stop = () => {
      stopped = true;
      container.removeEventListener("wheel", stop);
      container.removeEventListener("touchstart", stop);
    };
    container.addEventListener("wheel", stop, { passive: true });
    container.addEventListener("touchstart", stop, { passive: true });

    const step = () => {
      if (stopped || !container.isConnected) {
        return stop();
      }

      const item = container.querySelector(".--selected");
      if (!item) {
        return stop();
      }

      // offsetTop, not getBoundingClientRect: the list is the rows'
      // offsetParent (see language-tabs.scss), so this is the row's position
      // in the same unscaled coordinates as scrollTop. Viewport geometry
      // would be distorted by any transform on an ancestor.
      //
      // Scrolling the container directly, rather than item.scrollIntoView():
      // that walks up every scrollable ancestor and would drag the whole
      // preferences page along with it.
      const target = Math.max(0, item.offsetTop - SLACK_PX);

      if (Math.abs(container.scrollTop - target) > 1) {
        container.scrollTop = target;
        stable = 0;
      } else {
        stable += 1;
      }

      if (stable < STABLE_FRAMES && (frames += 1) < MAX_FRAMES) {
        requestAnimationFrame(step);
      } else {
        stop();
      }
    };

    requestAnimationFrame(step);
  }
}
