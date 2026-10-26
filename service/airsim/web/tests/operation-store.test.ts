import { beforeEach, expect, it } from 'vitest';
import { sessionOperationStore } from '../src/operation-store';
import { device } from './fixtures';

beforeEach(() => sessionStorage.clear());
it('stores only an operation id and display identity and removes it on completion', () => {
  const store = sessionOperationStore(sessionStorage);
  expect(store.load()).toBeUndefined();
  const operation = { id: 'test-operation', device };
  store.save(operation);
  expect(sessionOperationStore(sessionStorage).load()).toEqual(operation);
  store.clear();
  expect(store.load()).toBeUndefined();
});
it('rejects an incomplete recovery record instead of returning a new operation', () => {
  const store = sessionOperationStore(sessionStorage);
  sessionStorage.setItem('airsim.pending-device-operation', '{"id":"unfinished"}');
  expect(() => store.load()).toThrow();
});
