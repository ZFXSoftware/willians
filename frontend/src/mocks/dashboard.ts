export const dashboardMock = {
  balance: 18450.32,
  to_receive: 9230.15,
  matched: 27120.47,
  divergences: 540.22,

  transactions: [
    {
      date: "2026-05-01",
      description: "Mercado Livre",
      amount: 320.5,
      status: "matched",
    },
    {
      date: "2026-05-02",
      description: "Shopee",
      amount: 120.0,
      status: "pending",
    },
    {
      date: "2026-05-02",
      description: "Amazon",
      amount: 89.9,
      status: "divergent",
    },
    {
      date: "2026-05-03",
      description: "Magazine Luiza",
      amount: 540.0,
      status: "matched",
    },
  ],
}