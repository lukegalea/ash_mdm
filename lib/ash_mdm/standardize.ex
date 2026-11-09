# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshMdm.Standardize do
  @moduledoc """
  The closed vocabulary of standardizers a match rule can name. Each takes a
  lowercased, trimmed string and returns a string or nil, and they run in the
  order the rule lists them.

    * `unaccent` removes combining marks after a Latin base letter, so
      `Société` compares as `Societe`. Marks on other scripts are kept, since
      Devanagari, Thai and Japanese marks distinguish words.
    * `legal_suffix` removes trailing legal forms, so `Acme, Inc.` compares
      as `Acme`. Two different companies can share a stem, so a rule using
      this belongs in the review band rather than deciding a merge alone.
    * `lei` keeps a Legal Entity Identifier that passes its ISO 17442 check
      and returns nil for anything else. An invalid identifier is an absent
      one: it is never evidence of a match.

  A name that is nothing but a legal form keeps it, so `Limited` stays a name
  and doesn't become a blank that disagrees with every other record.
  """

  @standardizers ~w(unaccent legal_suffix lei)

  # Longest first, so a phrase is removed before any word inside it.
  @suffixes [
    ~w(limited liability company),
    ~w(limited liability partnership),
    ~w(public limited company),
    ~w(aktiengesellschaft),
    ~w(incorporated),
    ~w(corporation),
    ~w(company),
    ~w(limited),
    ~w(gmbh),
    ~w(sarl),
    ~w(corp),
    ~w(ltee),
    ~w(ltée),
    ~w(pllc),
    ~w(llc),
    ~w(llp),
    ~w(ltd),
    ~w(inc),
    ~w(plc),
    ~w(pty),
    ~w(ulc),
    ~w(srl),
    ~w(ag),
    ~w(bv),
    ~w(co),
    ~w(lp),
    ~w(nv),
    ~w(oy),
    ~w(sa),
    ~w(ab)
  ]

  @doc "The closed vocabulary."
  def standardizers, do: @standardizers

  @doc "Runs the named standardizers in order. Nil stays nil."
  @spec run(String.t() | nil, [String.t()]) :: String.t() | nil
  def run(value, names) when is_list(names) do
    Enum.reduce(names, value, fn
      _name, nil -> nil
      name, acc -> standardize(name, acc)
    end)
  end

  defp standardize("unaccent", value) do
    value
    |> String.normalize(:nfd)
    |> String.replace(~r/(\p{Latin})\p{Mn}+/u, "\\1")
    |> String.normalize(:nfc)
  end

  defp standardize("legal_suffix", value) do
    tokens = value |> String.split(~r/\s+/u, trim: true) |> Enum.map(&clean_token/1)

    case strip_suffixes(Enum.reverse(tokens)) do
      [] -> value
      kept -> kept |> Enum.reverse() |> Enum.join(" ")
    end
  end

  defp standardize("lei", value) do
    lei = String.upcase(value)
    if valid_lei?(lei), do: lei, else: nil
  end

  # `l.l.c.` and `inc,` are the same tokens as `llc` and `inc`.
  defp clean_token(token) do
    token |> String.replace(".", "") |> String.trim_trailing(",")
  end

  defp strip_suffixes(["" | rest]), do: strip_suffixes(rest)
  defp strip_suffixes(["&" | rest]), do: strip_suffixes(rest)

  defp strip_suffixes(reversed) do
    case Enum.find(@suffixes, &suffix?(reversed, &1)) do
      nil -> reversed
      suffix -> reversed |> Enum.drop(length(suffix)) |> strip_suffixes()
    end
  end

  defp suffix?(reversed, suffix), do: Enum.take(reversed, length(suffix)) == Enum.reverse(suffix)

  defp valid_lei?(lei) do
    Regex.match?(~r/^[0-9A-Z]{18}[0-9]{2}$/, lei) and rem(lei_number(lei), 97) == 1
  end

  defp lei_number(lei) do
    lei
    |> String.to_charlist()
    |> Enum.map_join(&(&1 |> digit_value() |> Integer.to_string()))
    |> String.to_integer()
  end

  defp digit_value(char) when char in ?0..?9, do: char - ?0
  defp digit_value(char), do: char - ?A + 10
end
