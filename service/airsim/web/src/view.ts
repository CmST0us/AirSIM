import { PairingController } from './controller';
import type { State } from './controller';
import type { Device, FailureCode } from './pairing';

function element<K extends keyof HTMLElementTagNameMap>(tag: K, className = '', text?: string) {
  const node = document.createElement(tag);
  node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

const failures: Record<FailureCode, [string, string]> = {
  cancelled: ['未选择设备', '选择设备，继续连接。'],
  busy: ['设备被占用', '关闭使用此设备的程序。选择设备，重试连接。'],
  disconnected: ['设备连接已断开', '检查电源和数据线。连接原设备。'],
  unsupported: ['设备不受支持', '选择受支持的设备。'],
  not_ready: ['设备未准备', '完成设备准备后重试。'],
  failed: ['连接失败', '检查设备电源和连接。选择设备，重试连接。'],
  unknown: ['无法读取设备', '检查设备连接。选择设备重试。'],
};

export function mountPairing(root: HTMLElement, controller: PairingController) {
  root.replaceChildren();
  const skip = element('a', 'skip', '跳到设备');
  skip.href = '#main-content';
  const header = element('header');
  const brand = element('span', 'brand', 'AirSIM');
  brand.append(element('small', '', '添加设备'));
  const helpButton = element('button', 'plain header-help', '连接帮助');
  helpButton.type = 'button';
  header.append(brand, helpButton);
  const main = element('main');
  const wrapper = element('div', 'document user-document');
  const content = element('section', 'content');
  content.id = 'main-content';
  content.setAttribute('aria-label', '添加设备');
  wrapper.append(content);
  main.append(wrapper);
  const dialog = element('dialog');
  dialog.setAttribute('aria-labelledby', 'help-title');
  const inner = element('div', 'dialog-inner');
  const dialogHead = element('div', 'dialog-head');
  const title = element('h2', '', '连接帮助');
  title.id = 'help-title';
  const close = element('button', 'close', '×');
  close.type = 'button';
  close.setAttribute('aria-label', '关闭');
  close.onclick = () => dialog.close();
  dialogHead.append(title, close);
  const help = element('div', 'help-list');
  for (const [label, copy] of [
    ['找不到设备', '检查设备电源和数据线。点击“选择设备”，核对设备名称。'],
    ['设备被占用', '关闭使用此设备的程序。选择设备，重试连接。'],
    ['连接结果未知', '保持原设备连接。点击“查询连接结果”。'],
  ]) {
    const details = element('details');
    details.append(element('summary', '', label), element('p', '', copy));
    help.append(details);
  }
  inner.append(dialogHead, help);
  dialog.append(inner);
  helpButton.onclick = () => dialog.showModal();
  dialog.onclick = event => { if (event.target === dialog) dialog.close(); };
  root.append(skip, header, main, dialog);
  let first = true;
  let previous: State | undefined;
  let expiryTimer: ReturnType<typeof setInterval> | undefined;

  function button(label: string, action: () => void, secondary = false) {
    const node = element('button', secondary ? 'plain' : 'primary', label);
    node.type = 'button';
    node.onclick = action;
    return node;
  }
  function deviceCard(device: Device, selectable = false) {
    const card = element(selectable ? 'button' : 'div', selectable ? 'device-choice' : 'device-summary');
    const copy = element('span');
    copy.append(element('strong', '', device.name), element('small', '', `设备标识 · ${device.shortId}`));
    card.append(copy);
    if (card instanceof HTMLButtonElement) {
      card.type = 'button';
      card.append(element('span', 'choice-label', '选择'));
      card.onclick = () => { void controller.chooseDevice(device.id); };
    }
    return card;
  }

  const unsubscribe = controller.subscribe((state: State) => {
    if (state.kind === 'awaiting_phone' && previous?.kind === 'awaiting_phone'
      && state.operation.id === previous.operation.id && state.code === previous.code
      && state.expiresAt === previous.expiresAt) return;
    previous = state;
    clearInterval(expiryTimer);
    content.replaceChildren();
    const heading = element('h1');
    heading.tabIndex = -1;
    const lead = element('p', 'lead');
    const actions = element('div', 'actions');
    content.append(heading, lead);
    const copy = (title: string, description: string) => {
      heading.textContent = title;
      lead.textContent = description;
    };
    const choose = () => { void controller.requestDevice(); };
    const query = () => { void controller.status(); };
    const loading = () => {
      const progress = element('div', 'loading-line');
      progress.setAttribute('aria-hidden', 'true');
      content.append(progress);
      lead.setAttribute('role', 'status');
    };
    switch (state.kind) {
      case 'mobile':
        copy('使用电脑连接', '打开电脑上的此页面，连接设备。');
        content.append(element('p', 'flow-note', '手机用于配对后的通话与短信。'));
        break;
      case 'unsupported':
        copy('更换浏览器', '使用电脑上的 Chrome 或 Edge 打开此页面。');
        break;
      case 'unavailable':
        copy('设备连接暂不可用', '刷新页面重试。');
        actions.append(button('刷新页面', () => window.location.reload()));
        break;
      case 'loading':
        copy('读取设备', '检查已连接的设备。'); loading(); break;
      case 'selecting':
        copy('选择设备', '在设备选择窗口中选择设备。'); loading(); break;
      case 'devices':
        copy(state.devices.length ? '添加设备' : '连接设备', state.devices.length ? '选择要连接的设备。' : '接通电源，用数据线连接电脑。');
        for (const device of state.devices) content.append(deviceCard(device, true));
        actions.append(button(state.devices.length ? '选择其他设备' : '选择设备', choose));
        break;
      case 'inspecting':
        copy('读取设备', '保持设备连接。');
        content.append(deviceCard(state.device)); loading(); break;
      case 'ready':
        copy('确认设备', '核对设备名称与标识。');
        content.append(deviceCard(state.device));
        actions.append(button('连接设备', () => { void controller.connect(); }), button('选择其他设备', choose, true));
        break;
      case 'awaiting_phone': {
        copy('输入连接码', '在 AirSIM 中添加设备，输入连接码。');
        content.append(deviceCard(state.operation.device));
        const code = element('output', 'connection-code', `${state.code.slice(0, 4)} ${state.code.slice(4)}`);
        code.setAttribute('aria-label', `连接码：${state.code.split('').join(' ')}`);
        const expiry = element('p', 'code-expiry');
        const updateExpiry = () => {
          const remaining = Math.max(0, Math.ceil((Date.parse(state.expiresAt) - Date.now()) / 1000));
          code.hidden = remaining === 0;
          expiry.textContent = remaining > 0
            ? `有效期 ${Math.floor(remaining / 60).toString().padStart(2, '0')}:${(remaining % 60).toString().padStart(2, '0')}`
            : '有效期已到，核对连接结果。';
        };
        updateExpiry();
        expiryTimer = setInterval(updateExpiry, 1000);
        content.append(code, expiry, element('p', 'flow-note', '等待手机确认。'));
        actions.append(button('取消', () => { void controller.cancel(); }, true));
        break;
      }
      case 'expired':
      case 'cancelled':
        copy(state.kind === 'expired' ? '连接码已过期' : '连接已取消', '设备配对未完成。');
        content.append(deviceCard(state.operation.device));
        actions.append(button('重新连接', () => { void controller.retry(); }));
        break;
      case 'cancelling':
        copy('取消连接', '核对连接结果。');
        content.append(deviceCard(state.operation.device)); loading(); break;
      case 'connecting':
      case 'checking':
        copy(state.kind === 'connecting' ? '等待设备响应' : '查询连接结果', '保持设备供电与数据线连接。');
        content.append(deviceCard(state.operation.device)); loading(); break;
      case 'pending':
        copy('等待设备响应', '保持设备供电与数据线连接。');
        content.append(deviceCard(state.operation.device));
        actions.append(button('查询连接结果', query)); break;
      case 'unknown':
        copy('连接结果未知', '连接原设备，查询本次结果。');
        content.append(deviceCard(state.operation.device));
        actions.append(button('查询连接结果', query)); break;
      case 'connected':
        copy(state.online ? '设备已连接' : '设备未联网', state.online ? '打开 AirSIM，查看设备。' : '连接已完成。检查设备电源和网络。');
        content.append(deviceCard(state.operation.device));
        if (!state.online) actions.append(button('检查连接状态', query));
        break;
      case 'failed': {
        const [title, description] = failures[state.code]; copy(title, description);
        if (state.device) content.append(deviceCard(state.device));
        actions.append(button('选择设备', choose)); break;
      }
    }
    if (actions.childElementCount) content.append(actions);
    if (!first && !dialog.open) heading.focus({ preventScroll: true });
    first = false;
  });
  return () => { clearInterval(expiryTimer); unsubscribe(); controller.dispose(); root.replaceChildren(); };
}
