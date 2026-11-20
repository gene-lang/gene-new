// A minimal view-owned browser contribution used by the outlet lifecycle test.
export function main(root) {
  const bridge = root.harness_bridge ?? root.harnessBridge;
  const view = bridge.view;
  root.dataset.mounted = '1';
  root.dataset.view = view.name;
  root.dataset.path = view.view_state.path;
  root.textContent = `view:${view.name}:${view.view_state.path}`;
  if (bridge.save_view_state) bridge.save_view_state({ path: 'chosen.gene' });
  root.harness_controller = {
    update(status) {
      root.dataset.updates = String(Number(root.dataset.updates || 0) + 1);
      root.dataset.ready = String(status.ready);
    },
    key(event) {
      if (event.key === 'k') {
        root.dataset.key = '1';
        return true;
      }
      return false;
    },
    dispose() {
      root.dataset.disposed = '1';
    },
  };
}
