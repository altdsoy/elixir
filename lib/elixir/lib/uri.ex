defmodule URI do
  @moduledoc """
  Utilities for working with and creating URIs.
  """

  defstruct scheme: nil, path: nil, query: nil,
            fragment: nil, authority: nil,
            userinfo: nil, host: nil, port: nil

  import Bitwise

  @ports %{
    "ftp"   => 21,
    "http"  => 80,
    "https" => 443,
    "ldap"  => 389,
    "sftp"  => 22,
    "tftp"  => 69,
  }

  Enum.each @ports, fn {scheme, port} ->
    def normalize_scheme(unquote(scheme)), do: unquote(scheme)
    def default_port(unquote(scheme)),     do: unquote(port)
  end

  @doc """
  Normalizes the scheme according to the spec by downcasing it.
  """
  def normalize_scheme(nil),     do: nil
  def normalize_scheme(scheme),  do: String.downcase(scheme)

  @doc """
  Returns the default port for a given scheme.

  If the scheme is unknown to URI, returns `nil`.
  Any scheme may be registered via `default_port/2`.

  ## Examples

      iex> URI.default_port("ftp")
      21

      iex> URI.default_port("ponzi")
      nil

  """
  def default_port(scheme) when is_binary(scheme) do
    {:ok, dict} = Application.fetch_env(:elixir, :uri)
    Map.get(dict, scheme)
  end

  @doc """
  Registers a scheme with a default port.

  It is recommended for this function to be invoked in your
  application start callback in case you want to register
  new URIs.
  """
  def default_port(scheme, port) when is_binary(scheme) and port > 0 do
    {:ok, dict} = Application.fetch_env(:elixir, :uri)
    Application.put_env(:elixir, :uri, Map.put(dict, scheme, port), persistent: true)
  end

  @doc """
  Encodes an enumerable into a query string.

  Takes an enumerable (containing a sequence of two-item tuples)
  and returns a string of the form "key1=value1&key2=value2..." where
  keys and values are URL encoded as per `encode/1`.

  Keys and values can be any term that implements the `String.Chars`
  protocol, except lists which are explicitly forbidden.

  ## Examples

      iex> hd = %{"foo" => 1, "bar" => 2}
      iex> URI.encode_query(hd)
      "bar=2&foo=1"

  """
  def encode_query(l), do: Enum.map_join(l, "&", &pair/1)

  @doc """
  Decodes a query string into a dictionary (by default uses a map).

  Given a query string of the form "key1=value1&key2=value2...", produces a
  map with one entry for each key-value pair. Each key and value will be a
  binary. Keys and values will be percent-unescaped.

  Use `query_decoder/1` if you want to iterate over each value manually.

  ## Examples

      iex> URI.decode_query("foo=1&bar=2")
      %{"bar" => "2", "foo" => "1"}

  """
  def decode_query(q, dict \\ %{}) when is_binary(q) do
    Enum.reduce query_decoder(q), dict, fn({k, v}, acc) -> Dict.put(acc, k, v) end
  end

  @doc """
  Returns an iterator function over the query string that decodes
  the query string in steps.

  ## Examples

      iex> URI.query_decoder("foo=1&bar=2") |> Enum.map &(&1)
      [{"foo", "1"}, {"bar", "2"}]

  """
  def query_decoder(q) when is_binary(q) do
    Stream.unfold(q, &do_decoder/1)
  end

  defp do_decoder("") do
    nil
  end

  defp do_decoder(q) do
    {first, next} =
      case :binary.split(q, "&") do
        [first, rest] -> {first, rest}
        [first]       -> {first, ""}
      end

    current =
      case :binary.split(first, "=") do
        [key, value] ->
          {decode_www_form(key), decode_www_form(value)}
        [key] ->
          {decode_www_form(key), nil}
      end

    {current, next}
  end

  defp pair({k, _}) when is_list(k) do
    raise ArgumentError, "encode_query/1 keys cannot be lists, got: #{inspect k}"
  end

  defp pair({_, v}) when is_list(v) do
    raise ArgumentError, "encode_query/1 values cannot be lists, got: #{inspect v}"
  end

  defp pair({k, v}) do
    encode_www_form(to_string(k)) <>
    "=" <> encode_www_form(to_string(v))
  end

  @doc """
  Checks if the character is a "reserved" character in a URI.

  Reserved characters are specified in RFC3986, section 2.2.
  """
  def char_reserved?(c) do
    c in ':/?#[]@!$&\'()*+,;='
  end

  @doc """
  Checks if the character is a "unreserved" character in a URI.

  Unreserved characters are specified in RFC3986, section 2.3.
  """
  def char_unreserved?(c) do
    c in ?0..?9 or
    c in ?a..?z or
    c in ?A..?Z or
    c in '~_-.'
  end

  @doc """
  Checks if the character is allowed unescaped in a URI.

  This is the default used by `URI.encode/2` where both
  reserved and unreserved characters are kept unescaped.
  """
  def char_unescaped?(c) do
    char_reserved?(c) or char_unreserved?(c)
  end

  @doc """
  Percent-escape a URI.
  Accepts `predicate` function as an argument to specify if char can be left as is.

  ## Example

      iex> URI.encode("ftp://s-ite.tld/?value=put it+й")
      "ftp://s-ite.tld/?value=put%20it+%D0%B9"

  """
  def encode(str, predicate \\ &char_unescaped?/1) when is_binary(str) do
    for <<c <- str>>, into: "", do: percent(c, predicate)
  end

  @doc """
  Encode a string as "x-www-urlencoded".

  ## Example

      iex> URI.encode_www_form("put: it+й")
      "put%3A+it%2B%D0%B9"

  """
  def encode_www_form(str) when is_binary(str) do
    for <<c <- str>>, into: "" do
      case percent(c, &char_unreserved?/1) do
        "%20" -> "+"
        pct   -> pct
      end
    end
  end

  defp percent(c, predicate) do
    if predicate.(c) do
      <<c>>
    else
      "%" <> hex(bsr(c, 4)) <> hex(band(c, 15))
    end
  end

  defp hex(n) when n <= 9, do: <<n + ?0>>
  defp hex(n), do: <<n + ?A - 10>>

  @doc """
  Percent-unescape a URI.

  ## Examples

      iex> URI.decode("http%3A%2F%2Felixir-lang.org")
      "http://elixir-lang.org"

  """
  def decode(uri) do
    unpercent(uri)
  catch
    :malformed_uri ->
      raise ArgumentError, "malformed URI #{inspect uri}"
  end

  @doc """
  Decode a string as "x-www-urlencoded".

  ## Examples

      iex> URI.decode_www_form("%3Call+in%2F")
      "<all in/"

  """
  def decode_www_form(str) do
    String.split(str, "+") |> Enum.map_join(" ", &unpercent/1)
  catch
    :malformed_uri ->
      raise ArgumentError, "malformed URI #{inspect str}"
  end

  defp unpercent(<<?%, hex_1, hex_2, tail :: binary>>) do
    <<bsl(hex_to_dec(hex_1), 4) + hex_to_dec(hex_2)>> <> unpercent(tail)
  end
  defp unpercent(<<?%, _>>), do: throw(:malformed_uri)
  defp unpercent(<<?%>>),    do: throw(:malformed_uri)

  defp unpercent(<<head, tail :: binary>>) do
    <<head>> <> unpercent(tail)
  end

  defp unpercent(<<>>), do: <<>>

  defp hex_to_dec(n) when n in ?A..?F, do: n - ?A + 10
  defp hex_to_dec(n) when n in ?a..?f, do: n - ?a + 10
  defp hex_to_dec(n) when n in ?0..?9, do: n - ?0
  defp hex_to_dec(_n), do: throw(:malformed_uri)

  @doc """
  Parses a URI into components.

  URIs have portions that are handled specially for the particular
  scheme of the URI. For example, http and https have different
  default ports. Such values can be accessed and registered via
  `URI.default_port/1` and `URI.default_port/2`.

  ## Examples

      iex> URI.parse("http://elixir-lang.org/")
      %URI{scheme: "http", path: "/", query: nil, fragment: nil,
           authority: "elixir-lang.org", userinfo: nil,
           host: "elixir-lang.org", port: 80}

  """
  def parse(s) when is_binary(s) do
    # From http://tools.ietf.org/html/rfc3986#appendix-B
    regex = ~r/^(([^:\/?#]+):)?(\/\/([^\/?#]*))?([^?#]*)(\?([^#]*))?(#(.*))?/
    parts = nillify(Regex.run(regex, s))

    destructure [_, _, scheme, _, authority, path, _, query, _, fragment], parts
    {userinfo, host, port} = split_authority(authority)

    if authority do
      authority = ""

      if userinfo, do: authority = authority <> userinfo <> "@"
      if host, do: authority = authority <> host
      if port, do: authority = authority <> ":" <> Integer.to_string(port)
    end

    scheme = normalize_scheme(scheme)

    if nil?(port) and not nil?(scheme) do
      port = default_port(scheme)
    end

    %URI{
      scheme: scheme, path: path, query: query,
      fragment: fragment, authority: authority,
      userinfo: userinfo, host: host, port: port
    }
  end

  # Split an authority into its userinfo, host and port parts.
  defp split_authority(s) do
    s = s || ""
    components = Regex.run ~r/(^(.*)@)?(\[[a-zA-Z0-9:.]*\]|[^:]*)(:(\d*))?/, s

    destructure [_, _, userinfo, host, _, port], nillify(components)
    port = if port, do: String.to_integer(port)
    host = if host, do: host |> String.lstrip(?[) |> String.rstrip(?])

    {userinfo, host, port}
  end

  # Regex.run returns empty strings sometimes. We want
  # to replace those with nil for consistency.
  defp nillify(l) do
    for s <- l do
      if byte_size(s) > 0, do: s, else: nil
    end
  end
end

defimpl String.Chars, for: URI do
  def to_string(uri) do
    scheme = uri.scheme

    if scheme && (port = URI.default_port(scheme)) do
      if uri.port == port, do: uri = %{uri | port: nil}
    end

    result = ""

    if uri.scheme,   do: result = result <> uri.scheme <> "://"
    if uri.userinfo, do: result = result <> uri.userinfo <> "@"
    if uri.host,     do: result = result <> uri.host
    if uri.port,     do: result = result <> ":" <> Integer.to_string(uri.port)
    if uri.path,     do: result = result <> uri.path
    if uri.query,    do: result = result <> "?" <> uri.query
    if uri.fragment, do: result = result <> "#" <> uri.fragment

    result
  end
end
