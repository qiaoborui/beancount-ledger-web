const DB_NAME = "beancount-ledger-web";
const DB_VERSION = 1;
const STORE_NAME = "ledger-cache";

type CacheRecord<T> = {
  key: string;
  value: T;
  updatedAt: number;
};

let dbPromise: Promise<IDBDatabase> | null = null;

function hasIndexedDB() {
  return typeof window !== "undefined" && "indexedDB" in window;
}

function openDb(): Promise<IDBDatabase> {
  if (!hasIndexedDB()) return Promise.reject(new Error("IndexedDB is not available"));
  if (dbPromise) return dbPromise;

  const promise: Promise<IDBDatabase> = new Promise((resolve, reject) => {
    const request = window.indexedDB.open(DB_NAME, DB_VERSION);

    request.onupgradeneeded = () => {
      const db = request.result;
      if (!db.objectStoreNames.contains(STORE_NAME)) db.createObjectStore(STORE_NAME, { keyPath: "key" });
    };

    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error ?? new Error("Failed to open IndexedDB"));
    request.onblocked = () => reject(new Error("IndexedDB open was blocked"));
  });

  dbPromise = promise.catch((error) => {
    dbPromise = null;
    throw error;
  });

  return dbPromise;
}

async function withStore<T>(mode: IDBTransactionMode, run: (store: IDBObjectStore) => IDBRequest<T>): Promise<T> {
  const db = await openDb();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(STORE_NAME, mode);
    const store = tx.objectStore(STORE_NAME);
    const request = run(store);

    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error ?? new Error("IndexedDB request failed"));
    tx.onerror = () => reject(tx.error ?? new Error("IndexedDB transaction failed"));
  });
}

export async function readIndexedCache<T>(key: string): Promise<T | null> {
  try {
    const record = await withStore<CacheRecord<T> | undefined>("readonly", (store) => store.get(key));
    return record?.value ?? null;
  } catch {
    return null;
  }
}

export async function writeIndexedCache<T>(key: string, value: T): Promise<void> {
  try {
    await withStore<IDBValidKey>("readwrite", (store) => store.put({ key, value, updatedAt: Date.now() } satisfies CacheRecord<T>));
  } catch {
    // IndexedDB may be unavailable in private mode or blocked by browser settings.
  }
}
