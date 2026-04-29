const PushSubscription = {
  mounted() {
    this.handleEvent("push:check_status", () => {
      this._checkSubscriptionStatus();
    });

    this.handleEvent("push:subscribe", () => {
      this._subscribe();
    });

    this.handleEvent("push:unsubscribe", () => {
      this._unsubscribe();
    });
  },

  async _checkSubscriptionStatus() {
    try {
      const permission = Notification.permission;
      const registration = await navigator.serviceWorker?.ready;
      const subscription = await registration?.pushManager?.getSubscription();

      // "Subscribed" must reflect *deliverability*, not just the existence
      // of a browser-side subscription. A subscription can exist while
      // Notification.permission has been revoked or never granted —
      // showing "Enabled" in that state misled us during debugging.
      const deliverable = !!subscription && permission === "granted";

      this.pushEvent("push:status", {
        permission: permission,
        subscribed: deliverable,
        // Send the full subscription so the server can re-register it if
        // its DeviceToken row is missing (browser side outliving server side).
        subscription: subscription ? JSON.stringify(subscription) : null,
      });
    } catch (err) {
      console.error("[Push] Status check failed:", err);
      this.pushEvent("push:status", {
        permission: "default",
        subscribed: false,
        subscription: null,
      });
    }
  },

  async _subscribe() {
    try {
      const permission = await Notification.requestPermission();
      if (permission !== "granted") {
        this.pushEvent("push:error", { reason: "permission_denied" });
        return;
      }

      const registration = await navigator.serviceWorker.ready;
      const vapidKey = document.querySelector('meta[name="vapid-public-key"]')?.content;

      if (!vapidKey) {
        this.pushEvent("push:error", { reason: "no_vapid_key" });
        return;
      }

      const subscription = await registration.pushManager.subscribe({
        userVisibleOnly: true,
        applicationServerKey: this._urlBase64ToUint8Array(vapidKey),
      });

      // Send subscription to server via LiveView event
      this.pushEvent("push:register_subscription", {
        subscription: JSON.stringify(subscription),
      });
    } catch (err) {
      console.error("[Push] Subscribe failed:", err);
      this.pushEvent("push:error", { reason: err.message });
    }
  },

  async _unsubscribe() {
    try {
      const registration = await navigator.serviceWorker.ready;
      const subscription = await registration.pushManager.getSubscription();

      if (subscription) {
        const subscriptionJson = JSON.stringify(subscription);
        await subscription.unsubscribe();

        // Tell server to remove the token
        this.pushEvent("push:remove_subscription", {
          subscription: subscriptionJson,
        });
      }

      this.pushEvent("push:unsubscribed", {});
    } catch (err) {
      console.error("[Push] Unsubscribe failed:", err);
      this.pushEvent("push:error", { reason: err.message });
    }
  },

  _urlBase64ToUint8Array(base64String) {
    const padding = "=".repeat((4 - (base64String.length % 4)) % 4);
    const base64 = (base64String + padding).replace(/-/g, "+").replace(/_/g, "/");
    const rawData = window.atob(base64);
    return Uint8Array.from([...rawData].map((char) => char.charCodeAt(0)));
  },
};

export default PushSubscription;
