export default function OfflinePage() {
  return (
    <main className="offline-page">
      <section>
        <div className="offline-mark" aria-hidden="true"><img src="/brand/cat-symbol-exact.png" alt="" /></div>
        <p className="eyebrow">SZAFUNEK • TRYB OFFLINE</p>
        <h1>Brak połączenia z internetem</h1>
        <p>
          Ze względów bezpieczeństwa grafiki, dane pracowników i ustawienia firmy nie są zapisywane offline.
          Połącz się z internetem, aby pobrać aktualne dane.
        </p>
        <a href="/">Spróbuj ponownie</a>
      </section>
    </main>
  );
}
