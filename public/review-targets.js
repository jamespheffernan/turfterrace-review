(function() {
  var dataEl = document.getElementById('reviewTargetsData');
  if (!dataEl) return;

  var state;
  try {
    state = JSON.parse(dataEl.textContent || '{}');
  } catch (_err) {
    return;
  }

  var reviewTargets = state.reviewTargets || { targets: [], summary: { total: 0, decided: 0, complete: true } };
  var positiveDecisions = new Set((state.positiveTargetDecisions || []).map(String));
  var isPending = state.isPending === true;
  var lists = Array.from(document.querySelectorAll('[data-review-target-list]'));
  var summaries = Array.from(document.querySelectorAll('[data-review-target-summary]'));
  var warnings = Array.from(document.querySelectorAll('[data-review-target-warning]'));
  if (!lists.length && !summaries.length) return;

  function escapeHtml(value) {
    return String(value || '')
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }

  function cssEscape(value) {
    if (window.CSS && typeof window.CSS.escape === 'function') return window.CSS.escape(value);
    return String(value || '').replace(/["\\]/g, '\\$&');
  }

  function statusLabel(target) {
    if (target.selectedOption && target.selectedOption.label) return target.selectedOption.label;
    if (target.verdict === 'approved') return 'Approved';
    if (target.verdict === 'rejected') return 'Rejected';
    return 'Open';
  }

  function summaryText(summary) {
    if (!summary || !summary.total) return 'No items';
    return String(summary.decided || 0) + ' of ' + String(summary.total) + ' decided';
  }

  function targetRow(target) {
    var verdict = target.verdict || 'unset';
    var rejected = verdict === 'rejected';
    var feedback = target.feedback || '';
    var controls = '';
    var isChoice = target.decisionKind === 'choice' && Array.isArray(target.options) && target.options.length > 1;
    var choiceButtons = isChoice ? target.options.map(function(option) {
      var optionVerdict = 'choice:' + option.value;
      return '<button type="button" class="review-target-action' + (verdict === optionVerdict ? ' active' : '') + '" data-target-key="' + escapeHtml(target.key) + '" data-verdict="' + escapeHtml(optionVerdict) + '">' + escapeHtml(option.label) + '</button>';
    }).join('') : '';

    if (isPending) {
      controls = [
        '<div class="review-target-actions" role="group" aria-label="Choose a decision">',
          isChoice ? choiceButtons : '<button type="button" class="review-target-action' + (verdict === 'approved' ? ' active' : '') + '" data-target-key="' + escapeHtml(target.key) + '" data-verdict="approved">Approve</button><button type="button" class="review-target-action' + (verdict === 'rejected' ? ' active' : '') + '" data-target-key="' + escapeHtml(target.key) + '" data-verdict="rejected">Reject</button>',
          verdict === 'unset' ? '' : '<button type="button" class="review-target-action review-target-action--reset" data-target-key="' + escapeHtml(target.key) + '" data-verdict="unset" aria-label="Reset review item state">Reset</button>',
        '</div>',
        isChoice ? '' : '<textarea class="review-target-feedback" data-target-feedback="' + escapeHtml(target.key) + '" rows="2" placeholder="Reason for rejection" ' + (rejected || feedback ? '' : 'hidden') + '>' + escapeHtml(feedback) + '</textarea>',
      ].join('');
    } else if (feedback) {
      controls = '<div class="review-target-feedback-readonly">' + escapeHtml(feedback) + '</div>';
    }

    return [
      '<div class="review-target-row ' + (verdict.startsWith('choice:') ? 'is-selected' : 'is-' + escapeHtml(verdict)) + '" data-review-target-key="' + escapeHtml(target.key) + '">',
        '<div class="review-target-row__main">',
          '<span class="review-target-label">' + escapeHtml(target.label) + '</span>',
          '<span class="review-target-state">' + statusLabel(target) + '</span>',
        '</div>',
        controls,
      '</div>',
    ].join('');
  }

  function paint() {
    summaries.forEach(function(el) {
      el.textContent = summaryText(reviewTargets.summary);
    });
    lists.forEach(function(list) {
      list.innerHTML = (reviewTargets.targets || []).map(targetRow).join('');
    });
    paintActionState();
  }

  function paintActionState() {
    var incomplete = isPending && reviewTargets.summary && reviewTargets.summary.total > 0 && !reviewTargets.summary.complete;
    warnings.forEach(function(el) {
      el.hidden = !incomplete;
    });
    document.querySelectorAll('.btn-action').forEach(function(button) {
      var decision = button.getAttribute('data-decision') || button.textContent.trim();
      if (!positiveDecisions.has(decision)) return;
      button.disabled = incomplete;
      button.classList.toggle('btn-action-disabled-by-targets', incomplete);
      if (incomplete) {
        button.setAttribute('title', 'Decide every item first');
      } else {
        button.removeAttribute('title');
      }
    });
  }

  async function updateTarget(key, verdict, feedback) {
    document.querySelectorAll('[data-target-key="' + cssEscape(key) + '"]').forEach(function(button) {
      button.disabled = true;
    });

    try {
      var res = await fetch('/api/items/' + encodeURIComponent(reviewTargets.slug) + '/targets/' + encodeURIComponent(key), {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ verdict: verdict, feedback: feedback || undefined }),
      });
      var data = await res.json();
      if (!res.ok) {
        throw new Error(data.error || 'Could not update item');
      }

      if (data.target) {
        reviewTargets.targets = (reviewTargets.targets || []).map(function(target) {
          return target.key === data.target.key ? data.target : target;
        });
      }
      if (data.summary) reviewTargets.summary = data.summary;
      paint();
    } catch (err) {
      if (window.showToast) window.showToast(err.message || 'Could not update item', { error: true });
      else alert(err.message || 'Could not update item');
      paint();
    }
  }

  document.addEventListener('click', function(event) {
    var button = event.target && event.target.closest ? event.target.closest('.review-target-action') : null;
    if (!button) return;
    var key = button.getAttribute('data-target-key');
    var verdict = button.getAttribute('data-verdict');
    if (!key || !verdict) return;

    var feedbackEl = document.querySelector('[data-target-feedback="' + cssEscape(key) + '"]');
    var feedback = feedbackEl ? feedbackEl.value.trim() : '';
    if (verdict === 'rejected' && feedbackEl) {
      feedbackEl.hidden = false;
      feedbackEl.focus();
    }
    updateTarget(key, verdict, verdict === 'rejected' ? feedback : '');
  });

  window.TurfReviewTargets = {
    showIncompleteWarning: function(summary) {
      if (summary) reviewTargets.summary = summary;
      paintActionState();
      warnings.forEach(function(el) {
        el.hidden = false;
      });
    },
  };

  paint();
})();

// Cached review HTML can outlive a template deployment. This bridge replaces
// the legacy selection handler without restarting the server; the canonical
// handler marks its container and makes this a no-op after the next restart.
(function installSafeTextAnnotationBridge() {
  var container = document.querySelector('.rendered-content:not(.rendered-content--fullpage)');
  if (!container || container.dataset.safeTextAnnotations) return;
  container.dataset.safeTextAnnotations = 'compat';

  var activeComposer = null;
  var selectionTimer = null;
  var selectionFrame = null;

  function removeComposer() {
    if (!activeComposer) return;
    activeComposer.remove();
    activeComposer = null;
  }

  function selectionPoint(event) {
    var touch = event.changedTouches && event.changedTouches[0];
    return {
      clientX: touch ? touch.clientX : event.clientX,
      clientY: touch ? touch.clientY : event.clientY,
      target: event.target,
    };
  }

  function charOffset(range) {
    var before = document.createRange();
    before.setStart(container, 0);
    before.setEnd(range.startContainer, range.startOffset);
    return before.toString().length;
  }

  function createComposer(quote, point, offset) {
    removeComposer();
    var composer = document.createElement('div');
    composer.className = 'annotation-popover annotation-popover--compat';
    composer.innerHTML =
      '<div class="annotation-popover-quote"><span>Selected text</span><q></q></div>' +
      '<div class="annotation-popover-row">' +
        '<input type="text" placeholder="Type your note\u2026" autocomplete="off">' +
        '<button type="button" class="annotation-popover-submit">Save</button>' +
        '<button type="button" class="annotation-popover-cancel" aria-label="Close">\u00d7</button>' +
      '</div>';
    composer.querySelector('q').textContent = quote;

    var maxLeft = Math.max(8, document.documentElement.scrollWidth - 308);
    var anchorX = Number.isFinite(point.clientX) ? point.clientX : 158;
    var anchorY = Number.isFinite(point.clientY) ? point.clientY : 0;
    composer.style.top = (anchorY + window.scrollY + 12) + 'px';
    composer.style.left = Math.min(maxLeft, Math.max(8, anchorX + window.scrollX - 150)) + 'px';
    document.body.appendChild(composer);
    activeComposer = composer;

    var input = composer.querySelector('input');
    var save = composer.querySelector('.annotation-popover-submit');
    var close = composer.querySelector('.annotation-popover-cancel');

    async function submit() {
      var comment = input.value.trim();
      if (!comment) {
        input.focus();
        return;
      }
      save.disabled = true;
      save.textContent = '\u2026';
      try {
        var response = await fetch('/api/items/' + encodeURIComponent(window.location.pathname.split('/').pop()) + '/annotate', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            quote: quote,
            anchor_type: 'text',
            anchor_ref: 'char:' + offset,
            comment: comment,
          }),
        });
        var annotation = await response.json();
        if (!response.ok) throw new Error(annotation.error || 'Could not save note');
        removeComposer();
        if (typeof renderAnnotation === 'function') renderAnnotation(annotation);
      } catch (error) {
        save.disabled = false;
        save.textContent = 'Save';
        if (window.showToast) window.showToast(error.message || 'Could not save note', { error: true });
      }
    }

    save.addEventListener('click', submit);
    close.addEventListener('click', removeComposer);
    input.addEventListener('keydown', function(event) {
      if (event.key === 'Enter') {
        event.preventDefault();
        submit();
      } else if (event.key === 'Escape') {
        removeComposer();
      }
    });
  }

  function handleSelection(point) {
    var selection = window.getSelection();
    if (!selection || selection.isCollapsed || !selection.toString().trim()) return;
    if (point.target && point.target.closest && point.target.closest('.annotation-highlight')) return;

    var range = selection.getRangeAt(0);
    var rangeNode = range.commonAncestorContainer.nodeType === Node.TEXT_NODE
      ? range.commonAncestorContainer.parentElement
      : range.commonAncestorContainer;
    if (!rangeNode || !container.contains(rangeNode)) return;

    var quote = selection.toString().trim();
    var offset = charOffset(range);
    selection.removeAllRanges();
    createComposer(quote, point, offset);
  }

  function scheduleSelection(event, delay) {
    // Stop the legacy bubble listener from focusing an input and starting
    // webkitSpeechRecognition inside Aside's native selection event.
    event.stopImmediatePropagation();
    var point = selectionPoint(event);
    clearTimeout(selectionTimer);
    if (selectionFrame !== null) cancelAnimationFrame(selectionFrame);
    selectionTimer = setTimeout(function() {
      selectionFrame = requestAnimationFrame(function() {
        selectionFrame = null;
        handleSelection(point);
      });
    }, delay || 0);
  }

  container.addEventListener('mouseup', function(event) {
    scheduleSelection(event, 0);
  }, true);
  container.addEventListener('touchend', function(event) {
    scheduleSelection(event, 300);
  }, true);
})();
