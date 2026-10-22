// Tiny DOM helpers plus the extension's equivalents of the shared_ui_kit widgets
// (AppIconButton, AppStatusDot, AppListRow, AppBanner, AppSegmentedControl,
// AppFieldLabel, AppTextField, AppEmptyMessage). Everything is built with DOM
// APIs and textContent so dynamic data never reaches innerHTML.
import { fluentIcon } from '../icons.js';

export { fluentIcon };

/**
 * h('div', { class: 'x', on: { click }, aria: { label: 'y' }, text: 'z' }, ...children)
 * `value`, `disabled`, `checked`, `hidden`, `required` are set as properties,
 * `aria` / `dataset` expand to aria-* / data-*, anything else is an attribute.
 */
export function h(tag, props = {}, ...children) {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(props || {})) {
    if (value === undefined || value === null || value === false) continue;
    if (key === 'class') node.className = value;
    else if (key === 'text') node.textContent = value;
    else if (key === 'on') for (const [type, fn] of Object.entries(value)) node.addEventListener(type, fn);
    else if (key === 'aria') for (const [name, v] of Object.entries(value)) node.setAttribute(`aria-${name}`, String(v));
    else if (key === 'dataset') Object.assign(node.dataset, value);
    else if (['value', 'disabled', 'checked', 'hidden', 'required', 'readOnly'].includes(key)) node[key] = value;
    else node.setAttribute(key, value === true ? '' : String(value));
  }
  append(node, children);
  return node;
}

export function append(node, children) {
  for (const child of children.flat(Infinity)) {
    if (child === null || child === undefined || child === false) continue;
    node.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }
  return node;
}

export function clear(node, ...children) {
  node.textContent = '';
  return append(node, children);
}

let ids = 0;
export const uid = (prefix = 'id') => `${prefix}-${++ids}`;

/** AppIconButton: 40px (compact 32px) icon-only button with a required label. */
export function iconButton(icon, label, onClick, { size = 'md', filled = false, className = '', type = 'button', disabled = false } = {}) {
  return h('button', {
    type,
    class: `icon-btn icon-btn-${size} ${className}`.trim(),
    title: label,
    disabled,
    aria: { label },
    on: onClick ? { click: onClick } : {},
  }, fluentIcon(icon, { filled }));
}

/** AppStatusDot: a coloured dot; the text label is for assistive tech and the title. */
export function statusDot(state, label) {
  return h('span', { class: `status-dot ${state}`, role: 'img', title: label, aria: { label } });
}

/** AppListRow / AppTreeRow: one selectable row with leading icon and optional trailing node. */
export function listRow({ icon, label, selected = false, onClick, trailing = null, depth = 0, expanded = null, caption = '' }) {
  const row = h('button', {
    type: 'button',
    class: `row${selected ? ' selected' : ''}`,
    style: depth ? `padding-left:${12 + depth * 16}px` : null,
    aria: expanded === null ? (selected ? { current: 'true' } : {}) : { expanded: String(expanded) },
    on: { click: onClick },
  });
  if (expanded !== null) row.append(fluentIcon(expanded ? 'chevronDown' : 'chevronRight'));
  if (icon) row.append(fluentIcon(icon, { filled: selected }));
  const text = h('span', { class: 'row-label', text: label });
  if (caption) text.append(h('small', { text: caption }));
  row.append(text);
  if (trailing) row.append(trailing);
  return row;
}

/** AppBanner. `kind` is info | error | warning. */
export function banner(kind, ...children) {
  return h('div', { class: `banner banner-${kind}`, role: kind === 'error' ? 'alert' : 'status' }, ...children);
}

/** AppEmptyMessage. */
export function emptyMessage(text) {
  return h('p', { class: 'empty', text });
}

/** AppFieldLabel. */
export function fieldLabel(text, forId) {
  return h('label', { class: 'field-label', for: forId, text });
}

/** AppTextField (label above the control). Returns { root, input }. */
export function textField({ label, id = uid('field'), multiline = false, helper = '', ...attrs }) {
  const input = h(multiline ? 'textarea' : 'input', { id, class: 'field', autocomplete: 'off', ...attrs });
  const root = h('div', { class: 'field-group' }, label && fieldLabel(label, id), input, helper && h('p', { class: 'helper', text: helper }));
  return { root, input };
}

/** AppDropdown: a native select styled like the kit. options: [{ value, label }]. */
export function dropdown({ label, id = uid('select'), options = [], value = '', onChange, disabled = false }) {
  const select = h('select', { id, class: 'field', disabled, on: onChange ? { change: () => onChange(select.value) } : {} },
    options.map((option) => h('option', { value: option.value, text: option.label })));
  select.value = value;
  const root = h('div', { class: 'field-group' }, label && fieldLabel(label, id), select);
  return { root, select };
}

/** AppSegmentedControl. */
export function segmented(label, options, selected, onSelect) {
  return h('div', { class: 'segmented', role: 'group', aria: { label } },
    options.map(([value, text]) => h('button', {
      type: 'button',
      aria: { pressed: String(selected === value) },
      text,
      on: { click: () => onSelect(value) },
    })));
}

/** AppButtonRow. */
export function buttonRow(...children) {
  return h('div', { class: 'button-row' }, ...children);
}

export function button(label, { kind = 'filled', icon = null, type = 'button', onClick, disabled = false, block = false } = {}) {
  return h('button', {
    type,
    class: `btn btn-${kind}${block ? ' btn-block' : ''}`,
    disabled,
    on: onClick ? { click: onClick } : {},
  }, icon && fluentIcon(icon), label);
}

/** AppFormError / notice line. */
export function errorLine(text) {
  return h('p', { class: 'form-error', role: 'alert', text, hidden: !text });
}

export function pageHeading(text) {
  return h('h1', { class: 'heading', text });
}
