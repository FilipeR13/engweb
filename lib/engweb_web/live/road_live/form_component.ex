defmodule EngwebWeb.RoadLive.FormComponent do
  use EngwebWeb, :live_component

  alias Engweb.Roads
  alias EngwebWeb.RoadLive.{CurrentImageUploader, ImageUploader}

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.header>
        <%= @title %>
      </.header>
      <%= if @action in [:delete, :delete_image, :delete_current_image] do %>
        <div class="flex justify-end">
          <.simple_form
            for={@form}
            id="road-form"
            phx-target={@myself}
            phx-submit="delete"
          >
          <:actions>
            <.button phx-disable-with="Deleting..." class="bg bg-red-600 hover:bg-red-700">Delete <%=
              if @action == :delete do
                "Road"
              else
                "Image"
              end
            %></.button>
          </:actions>
      </.simple_form>
      </div>
      <% else %>
        <.simple_form
          for={@form}
          id="road-form"
          phx-target={@myself}
          phx-change="validate"
          phx-submit="save"
          multipart
        >
          <.input field={@form[:num]} type="number" label="Num" />
          <.input field={@form[:name]} type="text" label="Name" />
          <.input field={@form[:description]} type="textarea" label="Description" />
          <%= if @action == :new do %>
            <div class="flex flex-col">
              <p class="mb-2">Images</p>
              <%= for index <- 0..(@uploads.image.max_entries - 1) do %>
                <p class="mb-2">Image <%= index + 1 %></p>
                <.live_component
                  module={ImageUploader}
                  id={"uploader_#{index + 1}"}
                  uploads={@uploads}
                  target={@myself}
                  index={index}
                  description={@descriptions[index] || ""}
                  class={
                    if length(@uploads.image.entries) < (index + 1) do
                      ""
                    else
                      "hidden"
                    end
                  }
                />
              <% end %>
            </div>
            <div>
              <p class="mb-2">Current Images</p>
              <.live_component module={CurrentImageUploader} id="uploader" uploads={@uploads} target={@myself} />
              </div>
          <% end %>
          <div class="flex flex-col gap-y-2">
            <%= for {_field, message} <- @error do %>
              <p class="text-red-500"><%= message %></p>
            <% end %>
          </div>
          <:actions>
            <.button phx-disable-with="Saving...">Save Road</.button>
          </:actions>
      </.simple_form>
      <% end %>
    </div>
    """
  end

  @impl true
  def update(%{road: road} = assigns, socket) do
    changeset = Roads.change_road(road)
    {:ok,
     socket
     |> allow_upload(:image, accept: ~w(.png .jpg .jpeg), max_entries: Roads.max_image_uploads())
     |> allow_upload(:current_image, accept: ~w(.png .jpg .jpeg), max_entries: Roads.max_current_image_uploads())
     |> assign(:descriptions, %{})
     |> assign(:uploaded_images, [])
     |> assign(:uploaded_current_images, [])
     |> assign(assigns)
     |> assign(:error, %{})
     |> assign_form(changeset)
    }
  end

  @impl true
  def handle_event("validate", %{"road" => road_params}, socket) do
    changeset =
      socket.assigns.road
      |> Roads.change_road(road_params)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("validate-description", %{"description_0" => description}, socket) do
    ref = Enum.at(socket.assigns.uploads.image.entries, 0).ref
    descriptions = Map.put(socket.assigns.descriptions, ref, description)
    {:noreply, assign(socket, :descriptions, descriptions)}
  end

  def handle_event("validate-description", %{"description_1" => description}, socket) do
    ref = Enum.at(socket.assigns.uploads.image.entries, 1).ref
    descriptions = Map.put(socket.assigns.descriptions, ref, description)
    {:noreply, assign(socket, :descriptions, descriptions)}
  end

  def handle_event("save", %{"road" => road_params}, socket) do
    case validate_images(socket) do
      {:error, socket} -> {:noreply, socket}
      {:ok, socket} -> save_road(socket, socket.assigns.action, road_params)
    end
  end

  def handle_event("delete", _params, socket) do
    delete(socket, socket.assigns.action)
  end

  def handle_event("cancel-image", %{"ref" => ref}, socket) do
    if socket.assigns.descriptions[ref] do
      descriptions = Map.delete(socket.assigns.descriptions, ref)
      {:noreply, socket |> assign(:descriptions, descriptions) |> cancel_upload(:image, ref)}
    else
      {:noreply, cancel_upload(socket, :image, ref)}
    end
  end

  def handle_event("cancel-current-image", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :current_image, ref)}
  end

  defp save_road(socket, :edit, road_params) do
    if socket.assigns.road.user_id != socket.assigns.current_user.id do
      {:noreply, socket |> put_flash(:error, "You are not allowed to edit this road")}
    else
      case Roads.update_road(socket.assigns.road, road_params) do
        {:ok, road} ->
          notify_parent({:saved, road})

          {:noreply,
          socket
          |> put_flash(:info, "Road updated successfully")
          |> push_patch(to: socket.assigns.patch)}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply, assign_form(socket, changeset)}
      end
    end
  end

  defp save_road(socket, :new, road_params) do
    id = socket.assigns.current_user.id
    if id == nil do
      {:noreply, socket |> put_flash(:error, "You must be logged in to create a road")}
    else
      case Map.put(road_params, "user_id", id) |> Roads.create_road() do
        {:ok, road} ->
          # join images with descriptions and create_images

          {:noreply, socket} = consume_uploaded_images(socket, :image)

          {:noreply, socket} = consume_uploaded_images(socket, :current_image)

          create_images(socket, road, :image)

          create_current_images(socket, road, :current_image)

          notify_parent({:saved, road})

          {:noreply,
          socket
          |> put_flash(:info, "Road created successfully")
          |> push_patch(to: socket.assigns.patch)}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply, assign_form(socket, changeset)}
      end
    end
  end

  defp delete(socket, :delete) do
    if socket.assigns.road.user_id != socket.assigns.current_user.id do
      {:noreply, socket |> put_flash(:error, "You are not allowed to delete this road")}
    else
      case Roads.delete_road(socket.assigns.road) do
        {:ok, _} ->
          notify_parent({:deleted, socket.assigns.road})

          {:noreply,
          socket
          |> put_flash(:info, "Road deleted successfully")
          |> redirect(to: socket.assigns.patch)}

        {:error, _} ->
          {:noreply, socket |> put_flash(:error, "Error deleting road")}
      end
    end
  end

  defp delete(socket, :delete_image) do
    image = Roads.get_image!(socket.assigns.id)
    IO.inspect(image)
    File.rm!(Path.join([:code.priv_dir(:engweb), "static", image.image]))

    case Roads.delete_image(image) do
      {:ok, _} ->
        {:noreply,
        socket
        |> put_flash(:info, "Image deleted successfully")
        |> push_patch(to: socket.assigns.patch)}

      {:error, _} ->
        {:noreply, socket |> put_flash(:error, "Error deleting image")}
    end
  end

  defp delete(socket, :delete_current_image) do
    current_image = Roads.get_current_image!(socket.assigns.id)
    IO.inspect(current_image)
    File.rm!(Path.join([:code.priv_dir(:engweb), "static", current_image.image]))

    case Roads.delete_current_image(current_image) do
      {:ok, _} ->
        {:noreply,
        socket
        |> put_flash(:info, "Current Image deleted successfully")
        |> push_patch(to: socket.assigns.patch)}

      {:error, _} ->
        {:noreply, socket |> put_flash(:error, "Error deleting current image")}
    end
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, :form, to_form(changeset))
  end

  defp notify_parent(msg), do: send(self(), {__MODULE__, msg})

  defp consume_uploaded_images(socket, :image) do
    uploaded_files =
      consume_uploaded_entries(socket, :image, fn %{path: path}, entry ->
        dest = Path.join([:code.priv_dir(:engweb), "static", "uploads", Path.basename(path)])

        File.cp!(path, dest)
        {:ok, {~p"/uploads/#{Path.basename(dest)}", socket.assigns.descriptions[entry.ref]}}
      end)

    {:noreply, update(socket, :uploaded_images, &(&1 ++ uploaded_files))}
  end

  defp consume_uploaded_images(socket, :current_image) do
    uploaded_files =
      consume_uploaded_entries(socket, :current_image, fn %{path: path}, _entry ->
        dest = Path.join([:code.priv_dir(:engweb), "static", "uploads", Path.basename(path)])
        File.cp!(path, dest)
        {:ok, ~p"/uploads/#{Path.basename(dest)}"}
      end)
    {:noreply, update(socket, :uploaded_current_images, &(&1 ++ uploaded_files))}
  end

  defp create_images(socket, road, :image) do
    Enum.each(socket.assigns.uploaded_images, fn path ->
      Roads.create_image(%{road_id: road.id, image: elem(path,0), legenda: elem(path,1)})
    end)
  end

  defp create_current_images(socket, road, :current_image) do
    Enum.each(socket.assigns.uploaded_current_images, fn path ->
      Roads.create_current_images(%{road_id: road.id, image: path})
    end)
  end

  defp validate_images(socket) do
    socket = validate_descriptions(socket)

    errors = socket.assigns.error

    errors =
      if length(socket.assigns.uploads.image.entries) == 0 do
        Map.put(errors, "min_image", "You must provide at least one image")
      else
        Map.delete(errors, "min_image")
      end

    errors =
      if length(socket.assigns.uploads.current_image.entries) == 0 do
        Map.put(errors, "min_current_image", "You must provide at least one current image")
      else
        Map.delete(errors, "min_current_image")
      end

    errors =
      if length(socket.assigns.uploads.image.entries) > socket.assigns.uploads.image.max_entries do
        Map.put(errors, "max_image", "You can only upload up to #{socket.assigns.uploads.image.max_entries} images")
      else
        Map.delete(errors, "max_image")
      end

    errors =
      if length(socket.assigns.uploads.current_image.entries) > socket.assigns.uploads.current_image.max_entries do
        Map.put(errors, "max_current_image", "You can only upload up to #{socket.assigns.uploads.current_image.max_entries} current images")
      else
        Map.delete(errors, "max_current_image")
      end

    if map_size(errors) > 0 do
      {:error, socket |> assign(:error, errors)}
    else
      {:ok, socket}
    end
  end

  defp validate_descriptions(socket) do
    errors =
      if length(socket.assigns.uploads.image.entries) != map_size(socket.assigns.descriptions) do
        Map.put(socket.assigns.error, "description", "You must provide a description for each image")
      else
        Map.delete(socket.assigns.error, "description")
      end

    assign(socket, :error, errors)
  end
end
