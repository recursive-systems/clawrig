This is a web application written using the Phoenix web framework.

## Project guidelines

- Use `mix precommit` alias when you are done with all changes and fix any pending issues
- Use the already included and available `:req` (`Req`) library for HTTP requests, **avoid** `:httpoison`, `:tesla`, and `:httpc`. Req is included by default and is the preferred HTTP client for Phoenix apps

### Phoenix v1.8 guidelines

- **Always** begin your LiveView templates with `<Layouts.app flash={@flash} ...>` which wraps all inner content
- The `MyAppWeb.Layouts` module is aliased in the `my_app_web.ex` file, so you can use it without needing to alias it again
- Anytime you run into errors with no `current_scope` assign:
  - You failed to follow the Authenticated Routes guidelines, or you failed to pass `current_scope` to `<Layouts.app>`
  - **Always** fix the `current_scope` error by moving your routes to the proper `live_session` and ensure you pass `current_scope` as needed
- Phoenix v1.8 moved the `<.flash_group>` component to the `Layouts` module. You are **forbidden** from calling `<.flash_group>` outside of the `layouts.ex` module
- Out of the box, `core_components.ex` imports an `<.icon name="hero-x-mark" class="w-5 h-5"/>` component for hero icons. **Always** use the `<.icon>` component for icons, **never** use `Heroicons` modules or similar
- **Always** use the imported `<.input>` component for form inputs from `core_components.ex` when available. `<.input>` is imported and using it will save steps and prevent errors
- If you override the default input classes (`<.input class="myclass px-2 py-1 rounded-lg">)`) class with your own values, no default classes are inherited, so your
custom classes must fully style the input


<!-- usage-rules-start -->

<!-- phoenix:elixir-start -->
## Elixir guidelines

- Elixir lists **do not support index based access via the access syntax**

  **Never do this (invalid)**:

      i = 0
      mylist = ["blue", "green"]
      mylist[i]

  Instead, **always** use `Enum.at`, pattern matching, or `List` for index based list access, ie:

      i = 0
      mylist = ["blue", "green"]
      Enum.at(mylist, i)

- Elixir variables are immutable, but can be rebound, so for block expressions like `if`, `case`, `cond`, etc
  you *must* bind the result of the expression to a variable if you want to use it and you CANNOT rebind the result inside the expression, ie:

      # INVALID: we are rebinding inside the `if` and the result never gets assigned
      if connected?(socket) do
        socket = assign(socket, :val, val)
      end

      # VALID: we rebind the result of the `if` to a new variable
      socket =
        if connected?(socket) do
          assign(socket, :val, val)
        end

- **Never** nest multiple modules in the same file as it can cause cyclic dependencies and compilation errors
- **Never** use map access syntax (`changeset[:field]`) on structs as they do not implement the Access behaviour by default. For regular structs, you **must** access the fields directly, such as `my_struct.field` or use higher level APIs that are available on the struct if they exist, `Ecto.Changeset.get_field/2` for changesets
- Elixir's standard library has everything necessary for date and time manipulation. Familiarize yourself with the common `Time`, `Date`, `DateTime`, and `Calendar` interfaces by accessing their documentation as necessary. **Never** install additional dependencies unless asked or for date/time parsing (which you can use the `date_time_parser` package)
- Don't use `String.to_atom/1` on user input (memory leak risk)
- Predicate function names should not start with `is_` and should end in a question mark. Names like `is_thing` should be reserved for guards
- Elixir's builtin OTP primitives like `DynamicSupervisor` and `Registry`, require names in the child spec, such as `{DynamicSupervisor, name: MyApp.MyDynamicSup}`, then you can use `DynamicSupervisor.start_child(MyApp.MyDynamicSup, child_spec)`
- Use `Task.async_stream(collection, callback, options)` for concurrent enumeration with back-pressure. The majority of times you will want to pass `timeout: :infinity` as option

## Mix guidelines

- Read the docs and options before using tasks (by using `mix help task_name`)
- To debug test failures, run tests in a specific file with `mix test test/my_test.exs` or run all previously failed tests with `mix test --failed`
- `mix deps.clean --all` is **almost never needed**. **Avoid** using it unless you have good reason

## Test guidelines

- **Always use `start_supervised!/1`** to start processes in tests as it guarantees cleanup between tests
- **Never** use `System.put_env/2` or `System.delete_env/1` in `async: true` tests — these mutate process-global state and cause flaky race conditions. Instead, make the module read from `Application.get_env(:clawrig, :some_key, default)` and set that key in test setup. Already configurable: `:auth_profiles_path`, `:codex_auth_path`
- **Avoid** `Process.sleep/1` and `Process.alive?/1` in tests
  - Instead of sleeping to wait for a process to finish, **always** use `Process.monitor/1` and assert on the DOWN message:

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

   - Instead of sleeping to synchronize before the next call, **always** use `_ = :sys.get_state/1` to ensure the process has handled prior messages
<!-- phoenix:elixir-end -->

<!-- phoenix:phoenix-start -->
## Phoenix guidelines

- Remember Phoenix router `scope` blocks include an optional alias which is prefixed for all routes within the scope. **Always** be mindful of this when creating routes within a scope to avoid duplicate module prefixes.

- You **never** need to create your own `alias` for route definitions! The `scope` provides the alias, ie:

      scope "/admin", AppWeb.Admin do
        pipe_through :browser

        live "/users", UserLive, :index
      end

  the UserLive route would point to the `AppWeb.Admin.UserLive` module

- `Phoenix.View` no longer is needed or included with Phoenix, don't use it
<!-- phoenix:phoenix-end -->

<!-- phoenix:html-start -->
## Phoenix HTML guidelines

- Phoenix templates **always** use `~H` or .html.heex files (known as HEEx), **never** use `~E`
- **Always** use the imported `Phoenix.Component.form/1` and `Phoenix.Component.inputs_for/1` function to build forms. **Never** use `Phoenix.HTML.form_for` or `Phoenix.HTML.inputs_for` as they are outdated
- When building forms **always** use the already imported `Phoenix.Component.to_form/2` (`assign(socket, form: to_form(...))` and `<.form for={@form} id="msg-form">`), then access those forms in the template via `@form[:field]`
- **Always** add unique DOM IDs to key elements (like forms, buttons, etc) when writing templates, these IDs can later be used in tests (`<.form for={@form} id="product-form">`)
- For "app wide" template imports, you can import/alias into the `my_app_web.ex`'s `html_helpers` block, so they will be available to all LiveViews, LiveComponent's, and all modules that do `use MyAppWeb, :html` (replace "my_app" by the actual app name)

- Elixir supports `if/else` but **does NOT support `if/else if` or `if/elsif`**. **Never use `else if` or `elseif` in Elixir**, **always** use `cond` or `case` for multiple conditionals.

  **Never do this (invalid)**:

      <%= if condition do %>
        ...
      <% else if other_condition %>
        ...
      <% end %>

  Instead **always** do this:

      <%= cond do %>
        <% condition -> %>
          ...
        <% condition2 -> %>
          ...
        <% true -> %>
          ...
      <% end %>

- HEEx require special tag annotation if you want to insert literal curly's like `{` or `}`. If you want to show a textual code snippet on the page in a `<pre>` or `<code>` block you *must* annotate the parent tag with `phx-no-curly-interpolation`:

      <code phx-no-curly-interpolation>
        let obj = {key: "val"}
      </code>

  Within `phx-no-curly-interpolation` annotated tags, you can use `{` and `}` without escaping them, and dynamic Elixir expressions can still be used with `<%= ... %>` syntax

- HEEx class attrs support lists, but you must **always** use list `[...]` syntax. You can use the class list syntax to conditionally add classes, **always do this for multiple class values**:

      <a class={[
        "px-2 text-white",
        @some_flag && "py-5",
        if(@other_condition, do: "border-red-500", else: "border-blue-100"),
        ...
      ]}>Text</a>

  and **always** wrap `if`'s inside `{...}` expressions with parens, like done above (`if(@other_condition, do: "...", else: "...")`)

  and **never** do this, since it's invalid (note the missing `[` and `]`):

      <a class={
        "px-2 text-white",
        @some_flag && "py-5"
      }> ...
      => Raises compile syntax error on invalid HEEx attr syntax

- **Never** use `<% Enum.each %>` or non-for comprehensions for generating template content, instead **always** use `<%= for item <- @collection do %>`
- HEEx HTML comments use `<%!-- comment --%>`. **Always** use the HEEx HTML comment syntax for template comments (`<%!-- comment --%>`)
- HEEx allows interpolation via `{...}` and `<%= ... %>`, but the `<%= %>` **only** works within tag bodies. **Always** use the `{...}` syntax for interpolation within tag attributes, and for interpolation of values within tag bodies. **Always** interpolate block constructs (if, cond, case, for) within tag bodies using `<%= ... %>`.

  **Always** do this:

      <div id={@id}>
        {@my_assign}
        <%= if @some_block_condition do %>
          {@another_assign}
        <% end %>
      </div>

  and **Never** do this – the program will terminate with a syntax error:

      <%!-- THIS IS INVALID NEVER EVER DO THIS --%>
      <div id="<%= @invalid_interpolation %>">
        {if @invalid_block_construct do}
        {end}
      </div>
<!-- phoenix:html-end -->

<!-- phoenix:liveview-start -->
## Phoenix LiveView guidelines

- **Never** use the deprecated `live_redirect` and `live_patch` functions, instead **always** use the `<.link navigate={href}>` and  `<.link patch={href}>` in templates, and `push_navigate` and `push_patch` functions LiveViews
- **Avoid LiveComponent's** unless you have a strong, specific need for them
- LiveViews should be named like `AppWeb.WeatherLive`, with a `Live` suffix. When you go to add LiveView routes to the router, the default `:browser` scope is **already aliased** with the `AppWeb` module, so you can just do `live "/weather", WeatherLive`

### LiveView streams

- **Always** use LiveView streams for collections for assigning regular lists to avoid memory ballooning and runtime termination with the following operations:
  - basic append of N items - `stream(socket, :messages, [new_msg])`
  - resetting stream with new items - `stream(socket, :messages, [new_msg], reset: true)` (e.g. for filtering items)
  - prepend to stream - `stream(socket, :messages, [new_msg], at: -1)`
  - deleting items - `stream_delete(socket, :messages, msg)`

- When using the `stream/3` interfaces in the LiveView, the LiveView template must 1) always set `phx-update="stream"` on the parent element, with a DOM id on the parent element like `id="messages"` and 2) consume the `@streams.stream_name` collection and use the id as the DOM id for each child. For a call like `stream(socket, :messages, [new_msg])` in the LiveView, the template would be:

      <div id="messages" phx-update="stream">
        <div :for={{id, msg} <- @streams.messages} id={id}>
          {msg.text}
        </div>
      </div>

- LiveView streams are *not* enumerable, so you cannot use `Enum.filter/2` or `Enum.reject/2` on them. Instead, if you want to filter, prune, or refresh a list of items on the UI, you **must refetch the data and re-stream the entire stream collection, passing reset: true**:

      def handle_event("filter", %{"filter" => filter}, socket) do
        # re-fetch the messages based on the filter
        messages = list_messages(filter)

        {:noreply,
         socket
         |> assign(:messages_empty?, messages == [])
         # reset the stream with the new messages
         |> stream(:messages, messages, reset: true)}
      end

- LiveView streams *do not support counting or empty states*. If you need to display a count, you must track it using a separate assign. For empty states, you can use Tailwind classes:

      <div id="tasks" phx-update="stream">
        <div class="hidden only:block">No tasks yet</div>
        <div :for={{id, task} <- @streams.tasks} id={id}>
          {task.name}
        </div>
      </div>

  The above only works if the empty state is the only HTML block alongside the stream for-comprehension.

- When updating an assign that should change content inside any streamed item(s), you MUST re-stream the items
  along with the updated assign:

      def handle_event("edit_message", %{"message_id" => message_id}, socket) do
        message = Chat.get_message!(message_id)
        edit_form = to_form(Chat.change_message(message, %{content: message.content}))

        # re-insert message so @editing_message_id toggle logic takes effect for that stream item
        {:noreply,
         socket
         |> stream_insert(:messages, message)
         |> assign(:editing_message_id, String.to_integer(message_id))
         |> assign(:edit_form, edit_form)}
      end

  And in the template:

      <div id="messages" phx-update="stream">
        <div :for={{id, message} <- @streams.messages} id={id} class="flex group">
          {message.username}
          <%= if @editing_message_id == message.id do %>
            <%!-- Edit mode --%>
            <.form for={@edit_form} id="edit-form-#{message.id}" phx-submit="save_edit">
              ...
            </.form>
          <% end %>
        </div>
      </div>

- **Never** use the deprecated `phx-update="append"` or `phx-update="prepend"` for collections

### LiveView JavaScript interop

- Remember anytime you use `phx-hook="MyHook"` and that JS hook manages its own DOM, you **must** also set the `phx-update="ignore"` attribute
- **Always** provide an unique DOM id alongside `phx-hook` otherwise a compiler error will be raised

LiveView hooks come in two flavors, 1) colocated js hooks for "inline" scripts defined inside HEEx,
and 2) external `phx-hook` annotations where JavaScript object literals are defined and passed to the `LiveSocket` constructor.

#### Inline colocated js hooks

**Never** write raw embedded `<script>` tags in heex as they are incompatible with LiveView.
Instead, **always use a colocated js hook script tag (`:type={Phoenix.LiveView.ColocatedHook}`)
when writing scripts inside the template**:

    <input type="text" name="user[phone_number]" id="user-phone-number" phx-hook=".PhoneNumber" />
    <script :type={Phoenix.LiveView.ColocatedHook} name=".PhoneNumber">
      export default {
        mounted() {
          this.el.addEventListener("input", e => {
            let match = this.el.value.replace(/\D/g, "").match(/^(\d{3})(\d{3})(\d{4})$/)
            if(match) {
              this.el.value = `${match[1]}-${match[2]}-${match[3]}`
            }
          })
        }
      }
    </script>

- colocated hooks are automatically integrated into the app.js bundle
- colocated hooks names **MUST ALWAYS** start with a `.` prefix, i.e. `.PhoneNumber`

#### External phx-hook

External JS hooks (`<div id="myhook" phx-hook="MyHook">`) must be placed in `assets/js/` and passed to the
LiveSocket constructor:

    const MyHook = {
      mounted() { ... }
    }
    let liveSocket = new LiveSocket("/live", Socket, {
      hooks: { MyHook }
    });

#### Pushing events between client and server

Use LiveView's `push_event/3` when you need to push events/data to the client for a phx-hook to handle.
**Always** return or rebind the socket on `push_event/3` when pushing events:

    # re-bind socket so we maintain event state to be pushed
    socket = push_event(socket, "my_event", %{...})

    # or return the modified socket directly:
    def handle_event("some_event", _, socket) do
      {:noreply, push_event(socket, "my_event", %{...})}
    end

Pushed events can then be picked up in a JS hook with `this.handleEvent`:

    mounted() {
      this.handleEvent("my_event", data => console.log("from server:", data));
    }

Clients can also push an event to the server and receive a reply with `this.pushEvent`:

    mounted() {
      this.el.addEventListener("click", e => {
        this.pushEvent("my_event", { one: 1 }, reply => console.log("got reply from server:", reply));
      })
    }

Where the server handled it via:

    def handle_event("my_event", %{"one" => 1}, socket) do
      {:reply, %{two: 2}, socket}
    end

### LiveView tests

- `Phoenix.LiveViewTest` module and `LazyHTML` (included) for making your assertions
- Form tests are driven by `Phoenix.LiveViewTest`'s `render_submit/2` and `render_change/2` functions
- Come up with a step-by-step test plan that splits major test cases into small, isolated files. You may start with simpler tests that verify content exists, gradually add interaction tests
- **Always reference the key element IDs you added in the LiveView templates in your tests** for `Phoenix.LiveViewTest` functions like `element/2`, `has_element/2`, selectors, etc
- **Never** tests again raw HTML, **always** use `element/2`, `has_element/2`, and similar: `assert has_element?(view, "#my-form")`
- Instead of relying on testing text content, which can change, favor testing for the presence of key elements
- Focus on testing outcomes rather than implementation details
- Be aware that `Phoenix.Component` functions like `<.form>` might produce different HTML than expected. Test against the output HTML structure, not your mental model of what you expect it to be
- When facing test failures with element selectors, add debug statements to print the actual HTML, but use `LazyHTML` selectors to limit the output, ie:

      html = render(view)
      document = LazyHTML.from_fragment(html)
      matches = LazyHTML.filter(document, "your-complex-selector")
      IO.inspect(matches, label: "Matches")

### Form handling

#### Creating a form from params

If you want to create a form based on `handle_event` params:

    def handle_event("submitted", params, socket) do
      {:noreply, assign(socket, form: to_form(params))}
    end

When you pass a map to `to_form/1`, it assumes said map contains the form params, which are expected to have string keys.

You can also specify a name to nest the params:

    def handle_event("submitted", %{"user" => user_params}, socket) do
      {:noreply, assign(socket, form: to_form(user_params, as: :user))}
    end

#### Creating a form from changesets

When using changesets, the underlying data, form params, and errors are retrieved from it. The `:as` option is automatically computed too. E.g. if you have a user schema:

    defmodule MyApp.Users.User do
      use Ecto.Schema
      ...
    end

And then you create a changeset that you pass to `to_form`:

    %MyApp.Users.User{}
    |> Ecto.Changeset.change()
    |> to_form()

Once the form is submitted, the params will be available under `%{"user" => user_params}`.

In the template, the form form assign can be passed to the `<.form>` function component:

    <.form for={@form} id="todo-form" phx-change="validate" phx-submit="save">
      <.input field={@form[:field]} type="text" />
    </.form>

Always give the form an explicit, unique DOM ID, like `id="todo-form"`.

#### Avoiding form errors

**Always** use a form assigned via `to_form/2` in the LiveView, and the `<.input>` component in the template. In the template **always access forms this**:

    <%!-- ALWAYS do this (valid) --%>
    <.form for={@form} id="my-form">
      <.input field={@form[:field]} type="text" />
    </.form>

And **never** do this:

    <%!-- NEVER do this (invalid) --%>
    <.form for={@changeset} id="my-form">
      <.input field={@changeset[:field]} type="text" />
    </.form>

- You are FORBIDDEN from accessing the changeset in the template as it will cause errors
- **Never** use `<.form let={f} ...>` in the template, instead **always use `<.form for={@form} ...>`**, then drive all form references from the form assign as in `@form[:field]`. The UI should **always** be driven by a `to_form/2` assigned in the LiveView module that is derived from a changeset
<!-- phoenix:liveview-end -->

<!-- usage-rules-end -->

## Subtree boundary

This directory (`projects/clawrig/clawrig/`) is a git subtree pushed to `recursive-systems/clawrig`. **Only project-idiomatic files belong here.** Agent workflow artifacts must live outside the subtree prefix:

| Artifact | Correct location | Wrong location |
|---|---|---|
| `.trajectories/` | `projects/clawrig/.trajectories/` | `projects/clawrig/clawrig/.trajectories/` |
| `.notes/` | `projects/clawrig/.notes/` | `projects/clawrig/clawrig/.notes/` |
| Validation results | `projects/clawrig/.trajectories/` | `projects/clawrig/clawrig/.trajectories/` |
| Decomposition plans | `projects/clawrig/` | `projects/clawrig/clawrig/` |

**Rule:** Never create `.trajectories/`, `.notes/`, `DECOMPOSITION.md`, or other agent-only artifacts inside `projects/clawrig/clawrig/`. They are gitignored there and will not be tracked. Place them at `projects/clawrig/` instead.

## OTP / GenServer guardrails

These rules were encoded after hardening review found recurring agent mistakes in ClawRig's GenServer modules.

### Never ignore return values from fallible operations

When calling a function that returns `:ok | {:error, reason}`, **always** match on the result and handle the error case. This applies especially to rollback, file operations, and system commands inside GenServers.

**Never do this:**

    rollback()
    File.rm(@pending_marker)
    # silently swallowed — if rollback fails, marker is deleted anyway

**Always do this:**

    case rollback() do
      :ok ->
        File.rm(@pending_marker)
        broadcast({:ok, :rolled_back})

      {:error, reason} ->
        Logger.error("Rollback failed: #{inspect(reason)} — keeping marker for retry")
        broadcast({:error, "rollback failed"})
    end

### Never use invalid atoms as sentinel values

When a function returns a value from a known set (e.g., `:station | :ap | :idle`), **never** use `:error` or other out-of-domain atoms as a fallback. Use a valid domain value.

**Never do this:**

    {:error, "connect_timeout_no_hotspot"}
    # :error is not a valid wifi mode — downstream pattern matches break

**Always do this:**

    {:idle, "connect_timeout_no_hotspot"}

### Always add `@impl true` on ALL callback clauses

When adding a new `handle_info`, `handle_call`, or `handle_cast` clause, **always** annotate it with `@impl true`. If there are multiple clauses for the same callback (e.g., pattern-matched on different messages), each group of clauses needs `@impl true` on the first clause.

### Guard timer-based handlers with activation flags

GenServers that start dormant and activate later (e.g., after OOBE) **must** guard their `:check` / timer handlers against the inactive state. Without this, a late-arriving timer message can start a duplicate check loop.

    @impl true
    def handle_info(:check, %{active: false} = state), do: {:noreply, state}

    def handle_info(:check, state) do
      state = do_check(state)
      schedule_check()
      {:noreply, state}
    end

Also guard the activation message to prevent double-activation:

    @impl true
    def handle_info(:oobe_complete, %{active: true} = state), do: {:noreply, state}

### Never block LiveView processes

**Never** put `Process.sleep/1`, synchronous `GenServer.call/2`, or long-running operations directly in a LiveView `handle_event` or `handle_info` callback. These block the LiveView process and freeze the UI.

**Always** use `Task.start/1` or `Task.async/1` for operations that may take more than a few milliseconds:

    # BAD — freezes the LiveView for 3+ seconds
    def handle_event("finalize", _, socket) do
      Manager.stop_hotspot()        # blocks
      Commands.start_gateway()      # blocks
      Process.sleep(3_000)          # blocks
      {:noreply, socket}
    end

    # GOOD — returns immediately, work happens in background
    def handle_event("finalize", _, socket) do
      Task.start(fn ->
        Manager.stop_hotspot()
        Commands.start_gateway()
      end)
      {:noreply, socket}
    end

### Use streaming for large file operations on Pi

The Pi has 1-2 GB RAM. **Never** read entire files into memory for checksumming or processing. Use `File.stream!/2` with a reasonable chunk size:

    # BAD — loads entire tarball into memory, can OOM
    data = File.read!(path)
    :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

    # GOOD — streams in 64KB chunks
    File.stream!(path, 65_536)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)

## Pi device validation

When validating a ClawRig release on a real Raspberry Pi, follow this workflow. Scripts live in `projects/clawrig/scripts/`.

### Prerequisites (human-only)

These steps require human action before an agent can proceed:

1. **1Password auth** — prefer `OP_SERVICE_ACCOUNT_TOKEN` on the host, or run `op signin`. Verify with `op whoami`.
2. **Env file** — copy `scripts/clawrig-pi-test.env.template` to `~/.config/clawrig-test/pi-test.env` and fill in values (or use `op://` references).
3. **Physical device** — ensure the Pi is powered on and connected to the network via Ethernet.
4. **Mode B approval** — if a full first-run reset is needed, the human must explicitly set `PI_VALIDATION_MODE=B` and `PI_MODE_B_APPROVED=1`. **Never** perform destructive resets without these being set.
5. **Automated Mode B transport** — if a script will remove `.oobe-complete` and drive the browser automatically, the Pi must remain reachable over ethernet after reset. A Wi-Fi-only Pi will re-enter hotspot mode and leave the home LAN, so `run-pi-e2e-happy-path.sh` is not the right tool for that case.
6. **Hotspot helper opt-in** — `run-pi-e2e-hotspot-happy-path.sh` is experimental/manual-only. Never run it unless the human explicitly wants the host Mac Wi‑Fi to switch and sets `PI_E2E_ALLOW_WIFI_HOST_SWITCH=1`.

### Agent-executable flow

```bash
# 0. Treat ~/.config/clawrig-test/pi-test.env as the active-device source of truth.
#    Prefer TEST_PI_HOST=.local, TEST_PI_HOST_FALLBACK_IP, and TEST_PI_EXPECT_HOSTNAME.

# 1. Discover the Pi on the local network
bash projects/clawrig/scripts/pi-discover.sh --env
# outputs: TEST_PI_HOST=<ip>

# 2. Resolve env file (auto-discovers Pi if --discover is set)
bash projects/clawrig/scripts/pi-test-env-resolve.sh --discover --output /tmp/clawrig-test-session.env

# 3. Build ARM64 release
CLAWRIG_VERSION=<version> bash projects/clawrig/clawrig/deploy/build-release.sh

# 4. Deploy to Pi (read env vars from resolved file)
eval "$(grep '^export TEST_PI' /tmp/clawrig-test-session.env)"
sshpass -p "$TEST_PI_PASS" scp -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
  projects/clawrig/clawrig/deploy/bundle/* "$TEST_PI_USER@$TEST_PI_HOST:~/clawrig-deploy/"
sshpass -p "$TEST_PI_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
  "$TEST_PI_USER@$TEST_PI_HOST" "cd ~/clawrig-deploy && sudo bash pi-setup.sh"

# 5. Restart and verify version
sshpass -p "$TEST_PI_PASS" ssh "$TEST_PI_USER@$TEST_PI_HOST" \
  "sudo systemctl restart clawrig && sleep 3 && cat /opt/clawrig/VERSION"

# 6. Run Mode A validation (non-destructive)
sshpass -p "$TEST_PI_PASS" ssh "$TEST_PI_USER@$TEST_PI_HOST" "bash -s" \
  < projects/clawrig/scripts/pi-verify.sh \
  | bash projects/clawrig/scripts/pi-record-result.sh \
    --version <version> --mode A --device <hostname> --device-ip <ip>
```

### Key rules

- **Always use explicit timeouts** on SSH and curl commands: `-o ConnectTimeout=10`, `--connect-timeout 10`
- **Never run Mode B without `PI_MODE_B_APPROVED=1`** — ask the human first
- **Never run automated reset-based Mode B on a Wi-Fi-only Pi** — use ethernet-backed reachability or do the hotspot/OOBE flow manually
- **Do not use the hotspot helper by default** — ethernet-backed validation remains the standard path
- If the human explicitly requests host Wi‑Fi switching, `projects/clawrig/scripts/run-pi-e2e-hotspot-happy-path.sh` requires `PI_E2E_ALLOW_WIFI_HOST_SWITCH=1`
- **Record results** using `pi-record-result.sh` — writes JSON to `projects/clawrig/.trajectories/` (outside the subtree prefix)
- **Device discovery** — mDNS hostnames go stale after identity reassignment. Always use `pi-discover.sh` or verify by IP if `.local` names don't resolve.
- **Env vars don't persist** between shell commands. Read from `/tmp/clawrig-test-session.env` in each command using `eval "$(grep '^export TEST_PI' /tmp/clawrig-test-session.env)"` or pass `--env-file`.
- **Active device source of truth** — check `~/.config/clawrig-test/pi-test.env` first before guessing which Pi to target.
- The acceptance matrix is at `projects/clawrig/docs/pi-acceptance.json` — use it to map OOBE test IDs to commands.
