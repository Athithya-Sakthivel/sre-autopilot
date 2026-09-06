import React from "react";
import ReactDOM from "react-dom/client";
import { BrowserRouter } from "react-router";
import { ApplicationInsights } from "@microsoft/applicationinsights-web";
import App from "./App";
import "./styles.css";
import "./types";

// Fallback to a safe value if build-time env is missing.
const APP_VERSION =
  (import.meta.env.VITE_APP_VERSION as string | undefined)?.trim() || "unknown";

function createApplicationInsights(): ApplicationInsights | undefined {
  const connectionString = window.APPINSIGHTS_CONNECTION_STRING?.trim();

  if (!connectionString) {
    console.warn(
      "Application Insights is disabled: APPINSIGHTS_CONNECTION_STRING is not configured.",
    );
    return undefined;
  }

  if (!/^InstrumentationKey=[^;]+(?:;.*)?$/i.test(connectionString)) {
    console.error(
      "Application Insights is disabled: APPINSIGHTS_CONNECTION_STRING does not look like a valid Azure Application Insights connection string.",
    );
    return undefined;
  }

  const appInsights = new ApplicationInsights({
    config: {
      connectionString,
      enableAutoRouteTracking: true,
      enableCorsCorrelation: true,
      enableRequestHeaderTracking: false,
      enableResponseHeaderTracking: false,
    },
  });

  // Attach AppVersion for canary and deployment correlation.
  appInsights.addTelemetryInitializer((envelope) => {
    envelope.tags = envelope.tags ?? {};
    envelope.tags["ai.application.ver"] = APP_VERSION;
    envelope.tags["ai.cloud.role"] = "task-api-frontend";
  });

  appInsights.loadAppInsights();
  appInsights.trackPageView();

  return appInsights;
}

const appInsights = createApplicationInsights();

window.appInsights = appInsights;

const rootElement = document.getElementById("root");

if (!rootElement) {
  throw new Error('Required root element "#root" was not found.');
}

ReactDOM.createRoot(rootElement).render(
  <React.StrictMode>
    <BrowserRouter>
      <App />
    </BrowserRouter>
  </React.StrictMode>,
);
