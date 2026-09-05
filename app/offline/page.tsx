export default function OfflinePage() {
  return (
    <main className="offline-page">
      <section>
        <div className="offline-mark" aria-hidden="true"><img src="/icons/szafunek-192.png" alt="" /></div>
        <p className="eyebrow">SZAFUNEK • TRYB OFFLINE</p>
        <h1>Brak połączenia z internetem</h1>
        <p>
          Sprawdź sieć i spróbuj ponownie. Ze względów bezpieczeństwa grafiki, dane pracowników
          i ustawienia firmy nie są zapisywane offline.
        </p>
        <a href="/">Spróbuj ponownie</a>
      </section>
    </main>
  );
}
