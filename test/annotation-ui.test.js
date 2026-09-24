const fs = require('fs');
const path = require('path');
const test = require('node:test');
const assert = require('node:assert/strict');

const reviewTemplate = fs.readFileSync(path.join(__dirname, '..', 'views', 'review.ejs'), 'utf8');
const reviewTargetsScript = fs.readFileSync(path.join(__dirname, '..', 'public', 'review-targets.js'), 'utf8');

function sourceBetween(start, end) {
  const startIndex = reviewTemplate.indexOf(start);
  const endIndex = reviewTemplate.indexOf(end, startIndex + start.length);
  assert.notEqual(startIndex, -1, `missing source marker: ${start}`);
  assert.notEqual(endIndex, -1, `missing source marker: ${end}`);
  return reviewTemplate.slice(startIndex, endIndex);
}

test('text selection defers DOM work and releases the native range first', () => {
  const selectionFlow = sourceBetween('// -- Text selection → popover --', 'function createPopover(options)');

  assert.match(selectionFlow, /requestAnimationFrame/);
  assert.match(selectionFlow, /sel\.removeAllRanges\(\);[\s\S]*document\.body\.appendChild\(pop\);/);
  assert.doesNotMatch(selectionFlow, /range\.getBoundingClientRect\(\)/);
  assert.doesNotMatch(selectionFlow, /input\.focus\(\)/);
  assert.doesNotMatch(selectionFlow, /startSpeechRecognition\(/);
});

test('annotation dictation starts only from the microphone button', () => {
  const popoverFlow = sourceBetween('function createPopover(options)', 'function setupPopoverHandlers');

  assert.match(popoverFlow, /micBtn\.onclick/);
  assert.match(popoverFlow, /input\.focus\(\);\s*startSpeechRecognition\(input, pop\);/);
  assert.match(popoverFlow, /placeholder="Type your note/);
  assert.match(popoverFlow, /annotation-popover-quote/);
});

test('cached review pages receive a safe static compatibility handler', () => {
  const bridgeScript = reviewTargetsScript.slice(reviewTargetsScript.indexOf('function installSafeTextAnnotationBridge'));

  assert.match(reviewTemplate, /container\.dataset\.safeTextAnnotations = 'canonical'/);
  assert.match(bridgeScript, /if \(!container \|\| container\.dataset\.safeTextAnnotations\) return/);
  assert.match(bridgeScript, /event\.stopImmediatePropagation\(\)/);
  assert.match(bridgeScript, /addEventListener\('mouseup',[\s\S]*true\)/);
  assert.match(bridgeScript, /selection\.removeAllRanges\(\);\s*createComposer/);
  assert.doesNotMatch(bridgeScript, /startSpeechRecognition\(|new\s+(?:webkit)?SpeechRecognition/);
});
