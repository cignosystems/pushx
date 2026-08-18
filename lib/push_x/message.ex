defmodule PushX.Message do
  @moduledoc """
  A struct representing a push notification message.

  Provides a builder API for constructing notifications with title, body,
  badge, sound, and custom data.

  ## Examples

      # Simple message
      message = PushX.Message.new("Hello", "World")

      # Builder pattern
      message = PushX.Message.new()
        |> PushX.Message.title("Order Update")
        |> PushX.Message.body("Your order has been shipped!")
        |> PushX.Message.badge(1)
        |> PushX.Message.sound("default")
        |> PushX.Message.data(%{order_id: "12345"})

      # iOS specifics and localization (also delivered to iOS via FCM)
      message = PushX.Message.new("Order Update", "Shipped!")
        |> PushX.Message.subtitle("Order #12345")
        |> PushX.Message.interruption_level(:time_sensitive)
        |> PushX.Message.mutable_content()
        |> PushX.Message.localized_body("ORDER_SHIPPED_BODY", ["12345"])

  Every field maps to both providers where the concept exists (see
  `to_apns_payload/1`, `to_fcm_payload/1`, `to_fcm_android/1`,
  `to_fcm_apns/1`); provider-only fields are silently ignored by the other.
  """

  @type t :: %__MODULE__{
          title: String.t() | nil,
          body: String.t() | nil,
          badge: non_neg_integer() | nil,
          sound: String.t() | nil,
          data: map(),
          category: String.t() | nil,
          thread_id: String.t() | nil,
          image: String.t() | nil,
          priority: :high | :normal | nil,
          ttl: non_neg_integer() | nil,
          collapse_key: String.t() | nil,
          subtitle: String.t() | nil,
          mutable_content: boolean(),
          content_available: boolean(),
          interruption_level: interruption_level() | nil,
          relevance_score: float() | nil,
          title_loc_key: String.t() | nil,
          title_loc_args: [String.t()] | nil,
          subtitle_loc_key: String.t() | nil,
          subtitle_loc_args: [String.t()] | nil,
          body_loc_key: String.t() | nil,
          body_loc_args: [String.t()] | nil
        }

  @typedoc "APNS interruption level (iOS 15+): how the notification may interrupt the user."
  @type interruption_level :: :passive | :active | :time_sensitive | :critical

  # priority defaults to nil (= let each provider apply its own default) so
  # that an unset struct never overrides provider rules such as APNS
  # requiring priority 5 for background pushes.
  defstruct [
    :title,
    :body,
    :badge,
    :sound,
    :category,
    :thread_id,
    :image,
    :ttl,
    :collapse_key,
    :priority,
    :subtitle,
    :interruption_level,
    :relevance_score,
    :title_loc_key,
    :title_loc_args,
    :subtitle_loc_key,
    :subtitle_loc_args,
    :body_loc_key,
    :body_loc_args,
    mutable_content: false,
    content_available: false,
    data: %{}
  ]

  @doc """
  Creates a new empty message.

  ## Examples

      iex> PushX.Message.new()
      %PushX.Message{title: nil, body: nil, data: %{}, priority: nil}

  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Creates a new message with title and body.

  ## Examples

      iex> PushX.Message.new("Hello", "World")
      %PushX.Message{title: "Hello", body: "World", data: %{}, priority: nil}

  """
  @spec new(String.t(), String.t()) :: t()
  def new(title, body) do
    %__MODULE__{title: title, body: body}
  end

  @doc """
  Sets the title of the message.
  """
  @spec title(t(), String.t()) :: t()
  def title(%__MODULE__{} = message, title) do
    %{message | title: title}
  end

  @doc """
  Sets the body of the message.
  """
  @spec body(t(), String.t()) :: t()
  def body(%__MODULE__{} = message, body) do
    %{message | body: body}
  end

  @doc """
  Sets the badge count (iOS).
  """
  @spec badge(t(), non_neg_integer()) :: t()
  def badge(%__MODULE__{} = message, badge) when is_integer(badge) and badge >= 0 do
    %{message | badge: badge}
  end

  @doc """
  Sets the notification sound.
  """
  @spec sound(t(), String.t()) :: t()
  def sound(%__MODULE__{} = message, sound) do
    %{message | sound: sound}
  end

  @doc """
  Sets custom data payload.
  """
  @spec data(t(), map()) :: t()
  def data(%__MODULE__{} = message, data) when is_map(data) do
    %{message | data: data}
  end

  @doc """
  Adds a key-value pair to the data payload.
  """
  @spec put_data(t(), atom() | String.t(), any()) :: t()
  def put_data(%__MODULE__{} = message, key, value) do
    %{message | data: Map.put(message.data, key, value)}
  end

  @doc """
  Sets the notification category (iOS).
  """
  @spec category(t(), String.t()) :: t()
  def category(%__MODULE__{} = message, category) do
    %{message | category: category}
  end

  @doc """
  Sets the thread ID for notification grouping (iOS).
  """
  @spec thread_id(t(), String.t()) :: t()
  def thread_id(%__MODULE__{} = message, thread_id) do
    %{message | thread_id: thread_id}
  end

  @doc """
  Sets the image URL for rich notifications.
  """
  @spec image(t(), String.t()) :: t()
  def image(%__MODULE__{} = message, image_url) do
    %{message | image: image_url}
  end

  @doc """
  Sets the priority (:high or :normal).
  """
  @spec priority(t(), :high | :normal) :: t()
  def priority(%__MODULE__{} = message, priority) when priority in [:high, :normal] do
    %{message | priority: priority}
  end

  @doc """
  Sets the TTL (time to live) in seconds.
  """
  @spec ttl(t(), non_neg_integer()) :: t()
  def ttl(%__MODULE__{} = message, ttl) when is_integer(ttl) and ttl >= 0 do
    %{message | ttl: ttl}
  end

  @doc """
  Sets the collapse key for message deduplication.
  """
  @spec collapse_key(t(), String.t()) :: t()
  def collapse_key(%__MODULE__{} = message, key) do
    %{message | collapse_key: key}
  end

  @doc """
  Sets the subtitle (APNS `alert.subtitle`; for FCM, delivered to iOS via the
  `apns` override).
  """
  @spec subtitle(t(), String.t()) :: t()
  def subtitle(%__MODULE__{} = message, subtitle) when is_binary(subtitle) do
    %{message | subtitle: subtitle}
  end

  @doc """
  Marks the notification as modifiable by a Notification Service Extension
  (APNS `mutable-content: 1`) — required for rich media (image attachments,
  decrypting content on device). Passes through to iOS via FCM too.
  """
  @spec mutable_content(t(), boolean()) :: t()
  def mutable_content(%__MODULE__{} = message, flag \\ true) when is_boolean(flag) do
    %{message | mutable_content: flag}
  end

  @doc """
  Sets APNS `content-available: 1`: wake the app in the background to fetch
  data. Combine with `PushX.push/4`'s `push_type: "background"` (and no
  title/body) for a silent push; with a visible alert it becomes an
  alert-plus-background-fetch notification.
  """
  @spec content_available(t(), boolean()) :: t()
  def content_available(%__MODULE__{} = message, flag \\ true) when is_boolean(flag) do
    %{message | content_available: flag}
  end

  @doc """
  Sets the APNS interruption level (iOS 15+): `:passive`, `:active`
  (default on the device), `:time_sensitive` (breaks through Focus; needs the
  Time Sensitive entitlement) or `:critical` (needs Apple's critical-alerts
  entitlement).
  """
  @spec interruption_level(t(), interruption_level()) :: t()
  def interruption_level(%__MODULE__{} = message, level)
      when level in [:passive, :active, :time_sensitive, :critical] do
    %{message | interruption_level: level}
  end

  @doc """
  Sets the APNS relevance score (`0.0`..`1.0`) used to sort notifications in
  the iOS notification summary.
  """
  @spec relevance_score(t(), float()) :: t()
  def relevance_score(%__MODULE__{} = message, score)
      when is_number(score) and score >= 0 and score <= 1 do
    %{message | relevance_score: score / 1}
  end

  @doc """
  Localizes the title with a key from the app's `Localizable.strings` and
  optional format arguments (APNS `title-loc-key`/`title-loc-args`, FCM
  `title_loc_key`/`title_loc_args`). Any literal title set with `title/2` is
  still sent as a fallback for clients without the key.
  """
  @spec localized_title(t(), String.t(), [String.t()]) :: t()
  def localized_title(%__MODULE__{} = message, key, args \\ [])
      when is_binary(key) and is_list(args) do
    %{message | title_loc_key: key, title_loc_args: args}
  end

  @doc "Localizes the subtitle (APNS `subtitle-loc-key`/`subtitle-loc-args`)."
  @spec localized_subtitle(t(), String.t(), [String.t()]) :: t()
  def localized_subtitle(%__MODULE__{} = message, key, args \\ [])
      when is_binary(key) and is_list(args) do
    %{message | subtitle_loc_key: key, subtitle_loc_args: args}
  end

  @doc """
  Localizes the body (APNS `loc-key`/`loc-args`, FCM `body_loc_key`/
  `body_loc_args`).
  """
  @spec localized_body(t(), String.t(), [String.t()]) :: t()
  def localized_body(%__MODULE__{} = message, key, args \\ [])
      when is_binary(key) and is_list(args) do
    %{message | body_loc_key: key, body_loc_args: args}
  end

  @doc """
  Converts the message to an APNS payload map.

  Note: when the message has a title but no explicit sound, `"default"` is
  injected — a titled notification is assumed to be user-visible. To send a
  visible-but-silent notification, build the raw APNS payload map yourself
  (omit `"sound"`) instead of using the `Message` builder.
  """
  @spec to_apns_payload(t()) :: map()
  def to_apns_payload(%__MODULE__{} = message) do
    alert = apns_alert(message)

    aps =
      %{}
      |> maybe_put("alert", if(alert != %{}, do: alert))
      |> maybe_put("badge", message.badge)
      |> maybe_put("sound", message.sound || if(message.title, do: "default"))
      |> maybe_put("category", message.category)
      |> maybe_put("thread-id", message.thread_id)
      |> Map.merge(apns_extras(message))

    %{"aps" => aps}
    |> Map.merge(Map.drop(message.data, ["aps", :aps]))
  end

  @doc """
  Translates the message's delivery fields into APNS send options.

  Returns a keyword list suitable for merging into the `opts` of
  `PushX.APNS.send/3` — explicit call-site options take precedence.

    * `priority: :high` → `priority: 10`, `priority: :normal` → `priority: 5`
    * `ttl` (seconds from now) → `expiration` (absolute Unix timestamp;
      `ttl: 0` maps to `expiration: 0`, APNS's "attempt once, don't store")
    * `collapse_key` → `collapse_id`

  ## Examples

      iex> PushX.Message.new("Hi", "There") |> PushX.Message.priority(:normal) |> PushX.Message.to_apns_options()
      [priority: 5]

  """
  @spec to_apns_options(t()) :: keyword()
  def to_apns_options(%__MODULE__{} = message) do
    []
    |> maybe_put_kw(
      :priority,
      case message.priority do
        :high -> 10
        :normal -> 5
        nil -> nil
      end
    )
    |> maybe_put_kw(
      :expiration,
      case message.ttl do
        nil -> nil
        0 -> 0
        ttl -> System.system_time(:second) + ttl
      end
    )
    |> maybe_put_kw(:collapse_id, message.collapse_key)
  end

  @doc """
  Translates the message's delivery fields into an FCM `android` block:
  `priority`, `ttl`, `collapse_key`, and — under `android.notification` —
  the title/body localization keys.

  Returns `nil` when none of them are set.

  ## Examples

      iex> PushX.Message.new("Hi", "There") |> PushX.Message.ttl(3600) |> PushX.Message.to_fcm_android()
      %{"ttl" => "3600s"}

      iex> PushX.Message.new("Hi", "There") |> PushX.Message.to_fcm_android()
      nil

  """
  @spec to_fcm_android(t()) :: map() | nil
  def to_fcm_android(%__MODULE__{} = message) do
    notification =
      %{}
      |> maybe_put("title_loc_key", message.title_loc_key)
      |> maybe_put("title_loc_args", if(message.title_loc_key, do: message.title_loc_args))
      |> maybe_put("body_loc_key", message.body_loc_key)
      |> maybe_put("body_loc_args", if(message.body_loc_key, do: message.body_loc_args))
      |> drop_empty_args()

    android =
      %{}
      |> maybe_put(
        "priority",
        case message.priority do
          :high -> "HIGH"
          :normal -> "NORMAL"
          nil -> nil
        end
      )
      |> maybe_put("ttl", if(message.ttl, do: "#{message.ttl}s"))
      |> maybe_put("collapse_key", message.collapse_key)
      |> maybe_put("notification", if(notification != %{}, do: notification))

    if android == %{}, do: nil, else: android
  end

  @doc """
  Converts the message to an FCM payload map.
  """
  @spec to_fcm_payload(t()) :: map()
  def to_fcm_payload(%__MODULE__{} = message) do
    notification =
      %{}
      |> maybe_put("title", message.title)
      |> maybe_put("body", message.body)
      |> maybe_put("image", message.image)

    if notification == %{} do
      %{}
    else
      %{"notification" => notification}
    end
  end

  # APNS `alert` dictionary: literal strings plus localization keys.
  defp apns_alert(%__MODULE__{} = message) do
    %{}
    |> maybe_put("title", message.title)
    |> maybe_put("subtitle", message.subtitle)
    |> maybe_put("body", message.body)
    |> maybe_put("title-loc-key", message.title_loc_key)
    |> maybe_put("title-loc-args", if(message.title_loc_key, do: message.title_loc_args))
    |> maybe_put("subtitle-loc-key", message.subtitle_loc_key)
    |> maybe_put("subtitle-loc-args", if(message.subtitle_loc_key, do: message.subtitle_loc_args))
    |> maybe_put("loc-key", message.body_loc_key)
    |> maybe_put("loc-args", if(message.body_loc_key, do: message.body_loc_args))
    |> drop_empty_args()
  end

  # `[]` args are omitted — Apple treats a missing key as "no arguments".
  defp drop_empty_args(alert), do: Map.reject(alert, fn {_k, v} -> v == [] end)

  # APNS `aps` keys outside `alert`.
  defp apns_extras(%__MODULE__{} = message) do
    %{}
    |> maybe_put("mutable-content", if(message.mutable_content, do: 1))
    |> maybe_put("content-available", if(message.content_available, do: 1))
    |> maybe_put("interruption-level", interruption_level_string(message.interruption_level))
    |> maybe_put("relevance-score", message.relevance_score)
  end

  defp interruption_level_string(nil), do: nil
  defp interruption_level_string(:time_sensitive), do: "time-sensitive"
  defp interruption_level_string(level), do: Atom.to_string(level)

  @doc """
  Translates the iOS-specific fields into an FCM `apns` override
  (`%{"payload" => %{"aps" => ...}}`) so they reach iOS devices addressed
  through FCM: `subtitle`, `mutable_content`, `content_available`,
  `interruption_level`, `relevance_score`, and the localization keys.

  Returns `nil` when none are set. Title/body/image travel in FCM's own
  `notification` block (`to_fcm_payload/1`); badge and sound in `android`/`apns`
  are left to callers' explicit `:apns`/`:android` options.

  ## Examples

      iex> PushX.Message.new("Hi", "There") |> PushX.Message.mutable_content() |> PushX.Message.to_fcm_apns()
      %{"payload" => %{"aps" => %{"mutable-content" => 1}}}

      iex> PushX.Message.new("Hi", "There") |> PushX.Message.to_fcm_apns()
      nil

  """
  @spec to_fcm_apns(t()) :: map() | nil
  def to_fcm_apns(%__MODULE__{} = message) do
    # Only the alert keys FCM does not already carry (it sends title/body).
    alert =
      message
      |> apns_alert()
      |> Map.drop(["title", "body"])

    aps =
      apns_extras(message)
      |> maybe_put("alert", if(alert != %{}, do: alert))

    if aps == %{}, do: nil, else: %{"payload" => %{"aps" => aps}}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_kw(kw, _key, nil), do: kw
  defp maybe_put_kw(kw, key, value), do: Keyword.put(kw, key, value)
end
