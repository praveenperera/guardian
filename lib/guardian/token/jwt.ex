defmodule Guardian.Token.Jwt do
  @moduledoc """
  Deals with things JWT
  """

  @behaviour Guardian.Token

  alias Guardian.Config
  import Guardian, only: [stringify_keys: 1]

  @default_algos ["HS512"]
  @default_token_type "access"
  @type_key "typ"
  @default_ttl {4, :weeks}

  def peek(nil), do: nil
  def peek(token) do
    %{
      headers: JOSE.JWT.peek_protected(token).fields,
      claims: JOSE.JWT.peek_payload(token).fields
    }
  end

  def token_id, do: UUID.uuid4

  def create_token(mod, claims, options \\ []) do
    secret = fetch_secret(mod, options)

    {_, token} =
      secret
      |> jose_jwk()
      |> JOSE.JWT.sign(jose_jws(mod, options), claims)
      |> JOSE.JWS.compact()

    {:ok, token}
  end

  # credo:disable-for-next-line /\.Warning\./
  def build_claims(
    mod,
    _resource,
    sub,
    claims \\ %{},
    options \\ []
  ) do
    claims
    |> stringify_keys()
    |> set_jti()
    |> set_iat()
    |> set_iss(mod, options)
    |> set_aud(mod, options)
    |> set_type(mod, options)
    |> set_sub(mod, sub, options)
    |> set_ttl(mod, options)
  end

  def decode_token(mod, token, options \\ []) do
    secret =
      mod
      |> fetch_secret(options)
      |> jose_jwk()

    case JOSE.JWT.verify_strict(secret, fetch_allowed_algos(mod, options), token) do
      {true, jose_jwt, _} ->  {:ok, jose_jwt.fields}
      {false, _, _} -> {:error, :invalid_token}
    end
  end

  def verify_claims(mod, claims, options) do
    result =
      mod
      |> apply(:config, [:token_verify_module, Guardian.Token.Jwt.Verify])
      |> apply(:verify_claims, [mod, claims, options])
    case result do
      {:ok, claims} ->
        apply(mod, :verify_claims, [claims, options])
      err -> err
    end
  end

  def revoke(_mod, claims, _token, _options), do: {:ok, claims}

  def refresh(mod, old_token, options) do
    with {:ok, old_claims} <- apply(
                            mod,
                            :decode_and_verify,
                            [old_token, %{}, options]
                          ),
         {:ok, claims} <- refresh_claims(mod, old_claims, options),
         {:ok, token} <- create_token(mod, claims, options)
    do
      {:ok, {old_token, old_claims}, {token, claims}}
    else
      {:error, _} = err -> err
      err -> {:error, err}
    end
  end

  def exchange(mod, old_token, from_type, to_type, options) do
    with {:ok, old_claims} <- apply(
                            mod,
                            :decode_and_verify,
                            [old_token, %{}, options]
                          ),
         {:ok, claims} <-
           exchange_claims(mod, old_claims, from_type, to_type, options),
         {:ok, token} <- create_token(mod, claims, options)
    do
      {:ok, {old_token, old_claims}, {token, claims}}
    else
      {:error, _} = err -> err
      err -> {:error, err}
    end
  end

  defp jose_jws(mod, opts) do
    algos = fetch_allowed_algos(mod, opts) || @default_algos
    headers = Keyword.get(opts, :headers, %{})
    Map.merge(%{"alg" => hd(algos)}, headers)
  end

  defp jose_jwk(the_secret = %JOSE.JWK{}), do: the_secret
  defp jose_jwk(the_secret) when is_binary(the_secret), do: JOSE.JWK.from_oct(the_secret)
  defp jose_jwk(the_secret) when is_map(the_secret), do: JOSE.JWK.from_map(the_secret)
  defp jose_jwk(value), do: Config.resolve_value(value)

  defp fetch_allowed_algos(mod, opts) do
    allowed = Keyword.get(opts, :allowed_algos)
    if allowed do
      Guardian.Config.resolve_value(allowed)
    else
      mod
      |> apply(:config, [:allowed_algos, @default_algos])
    end
  end

  defp fetch_secret(mod, opts) do
    secret = Keyword.get(opts, :secret)
    if secret do
      Guardian.Config.resolve_value(secret)
    else
      mod
      |> apply(:config, [:secret_key])
    end
  end

  defp set_type(%{"typ" => typ} = claims, _mod, _opts) when not is_nil(typ) do
    claims
  end

  defp set_type(claims, mod, opts) do
    typ = Keyword.get(
      opts,
      :token_type,
      apply(mod, :default_token_type, [])
    )
    Map.put(claims, @type_key, to_string(typ || @default_token_type))
  end

  defp set_sub(claims, _mod, subject, _opts) do
    Map.put(claims, "sub", subject)
  end

  defp set_iat(claims) do
    ts = Guardian.timestamp()
    claims
    |> Map.put("iat", ts)
    |> Map.put("nbf", ts - 1)
  end

  defp set_ttl(%{"exp" => exp} = claims, _mod, _opts) when not is_nil(exp) do
    claims
  end

  defp set_ttl(%{"typ" => token_typ} = claims, mod, opts) do
    ttl = Keyword.get(opts, :ttl)
    if ttl do
      set_ttl(claims, ttl)
    else
      ttl =
        mod
        |> apply(:config, [:token_ttl, %{}])
        |> Map.get(
          to_string(token_typ),
          apply(mod, :config, [:ttl, @default_ttl])
        )
      set_ttl(claims, ttl)
    end
  end

  defp set_ttl(the_claims, {num, period}) when is_binary(num) do
    set_ttl(the_claims, {String.to_integer(num), period})
  end

  defp set_ttl(the_claims, {num, period}) when is_binary(period) do
    set_ttl(the_claims, {num, String.to_existing_atom(period)})
  end

  defp set_ttl(%{"iat" => iat_v} = the_claims, requested_ttl) do
    assign_exp_from_ttl(the_claims, {iat_v, requested_ttl})
  end

  # catch all for when the issued at iat is not yet set
  defp set_ttl(claims, requested_ttl) do
    claims
    |> set_iat()
    |> set_ttl(requested_ttl)
  end

  defp assign_exp_from_ttl(the_claims, {iat_v, {seconds, unit}})
  when unit in [:second, :seconds] do
    Map.put(the_claims, "exp", iat_v + seconds)
  end

  defp assign_exp_from_ttl(the_claims, {iat_v, {minutes, unit}})
  when unit in [:minute, :minutes] do
    Map.put(the_claims, "exp", iat_v + minutes * 60)
  end

  defp assign_exp_from_ttl(the_claims, {iat_v, {hours, unit}})
  when unit in [:hour, :hours] do
    Map.put(the_claims, "exp", iat_v + hours * 60 * 60)
  end

  defp assign_exp_from_ttl(the_claims, {iat_v, {days, unit}})
  when unit in [:day, :days] do
    Map.put(the_claims, "exp", iat_v + days * 24 * 60 * 60)
  end

  defp assign_exp_from_ttl(the_claims, {iat_v, {weeks, unit}})
  when unit in [:week, :weeks] do
    Map.put(the_claims, "exp", iat_v + weeks * 7 * 24 * 60 * 60)
  end

  defp assign_exp_from_ttl(_, {_iat_v, {_, units}}) do
    raise "Unknown Units: #{units}"
  end

  defp set_iss(claims, mod, _opts) do
    issuer = apply(mod, :config, [:issuer])
    Map.put(claims, "iss", to_string(issuer))
  end

  defp set_aud(%{"aud" => aud} = claims, _mod, _opts) when not is_nil(aud) do
    claims
  end
  defp set_aud(claims, mod, _opts) do
    issuer = apply(mod, :config, [:issuer])
    Map.put(claims, "aud", to_string(issuer))
  end

  defp set_jti(claims) do
    Map.put(claims, "jti", token_id())
  end

  defp refresh_claims(mod, claims, options) do
    {:ok, reset_claims(mod, claims, options)}
  end

  defp exchange_claims(mod, old_claims, from_type, to_type, options)
  when is_list(from_type)
  do
    from_type = Enum.map(from_type, &(to_string(&1)))

    if Enum.member?(from_type, old_claims["typ"]) do
      exchange_claims(mod, old_claims, old_claims["typ"], to_type, options)
    else
      {:error, :incorrect_token_type}
    end
  end

  defp exchange_claims(mod, old_claims, from_type, to_type, options) do
    if old_claims["typ"] == to_string(from_type) do
      # set the type first because the ttl can depend on the type
      claims = Map.put(old_claims, "typ", to_string(to_type))
      claims = reset_claims(mod, claims, options)
      {:ok, claims}
    else
      {:error, :incorrect_token_type}
    end
  end

  defp reset_claims(mod, claims, options) do
    claims
    |> Map.drop(["jti", "iss", "iat", "nbf", "exp"])
    |> set_jti()
    |> set_iat()
    |> set_iss(mod, options)
    |> set_ttl(mod, options)
  end
end