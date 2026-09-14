# Render + React Deployment Guide for Buy or Wait?

## 1. What this project is today

This repo is currently a Ruby data-processing challenge project, not a web app. The entry point is:

```bash
ruby code/main.rb
```

It reads CSV files under `dataset/` and writes a root-level `output.csv` file. That means:

- It is fully runnable from the terminal.
- It is not yet a live API or UI.
- You can deploy it to Render, but you should wrap it in a small web service first.

## 2. Can it be made live?

Yes — with a simple architecture:

- Backend service: runs the Ruby logic and exposes an API
- Frontend: React UI that lets users upload data / trigger analysis
- Render: hosts the backend and frontend as separate services

This is the cleanest approach because the actual decision engine is already built in Ruby and can be reused without rewriting the business logic.

## 3. Recommended architecture

```text
React Frontend (Vite)
        |
        | HTTP requests
        v
Backend API (Ruby / Rack or Node / Express)
        |
        | calls Pipeline.run
        v
CSV dataset + output generation
```

The key idea is:

- keep the financial logic in the current Ruby project
- expose it through a minimal API
- build a React dashboard on top

## 4. Best production setup for Render

### Option A: Two Render services (recommended)

1. `backend` service
   - runs Ruby API
   - handles request processing
   - writes `output.csv`
2. `frontend` service
   - runs Vite React app
   - calls backend API

### Option B: Single Render service

- host the React app and proxy API requests to a serverless or Node backend
- possible, but more complicated

For this project, Option A is the easiest and most reliable.

## 5. Backend API plan

Create a small Ruby API wrapper around the current logic. Example concept:

```ruby
# api/server.rb
require 'sinatra'
require 'json'
require 'fileutils'

require_relative '../code/lib/pipeline'

set :port, ENV.fetch('PORT', 3000)

post '/api/run' do
  content_type :json

  dataset_dir = File.expand_path('../dataset', __dir__)
  output_path = File.expand_path('../output.csv', __dir__)

  begin
    stats = Pipeline.run(output_path: output_path)
    {
      ok: true,
      output_path: output_path,
      requests_processed: stats.requests_processed,
      output_rows: stats.output_rows
    }.to_json
  rescue StandardError => e
    status 500
    { ok: false, error: e.message }.to_json
  end
end
```

Then add a minimal `Gemfile`:

```ruby
source 'https://rubygems.org'
gem 'sinatra'
```

`config.ru`:

```ruby
require './api/server'
run Sinatra::Application
```

Start command on Render:

```bash
bundle install && rackup --host 0.0.0.0 -p $PORT
```

## 6. Frontend React plan

In the repo root:

```bash
npm create vite@latest frontend -- --template react
cd frontend
npm install axios
```

Then create a simple screen:

- Upload or select dataset
- Click `Run analysis`
- Show loading state
- Display generated `output.csv` preview

Example React call:

```jsx
import axios from 'axios';

const runAnalysis = async () => {
  const res = await axios.post(`${import.meta.env.VITE_API_URL}/api/run`);
  console.log(res.data);
};
```

## 7. Render deployment steps

### Backend service

In Render:

- New Web Service
- Connect GitHub repo
- Root directory: repo root
- Build command:

```bash
bundle install
```

- Start command:

```bash
rackup --host 0.0.0.0 -p $PORT
```

Environment variables:

```bash
PORT=3000
```

### Frontend service

In Render:

- New Static Site or Web Service
- Root directory: `frontend`
- Build command:

```bash
npm install && npm run build
```

- Publish directory:

```bash
dist
```

Environment variables:

```bash
VITE_API_URL=https://your-backend-render-url
```

## 8. Example Vite app structure

```text
frontend/
  src/
    App.jsx
    main.jsx
    index.css
  package.json
  vite.config.js
```

Example `App.jsx` structure:

```jsx
export default function App() {
  const runAnalysis = async () => {
    const response = await fetch(`${import.meta.env.VITE_API_URL}/api/run`, {
      method: 'POST'
    });

    const data = await response.json();
    alert(data.ok ? 'Analysis complete' : data.error);
  };

  return (
    <div>
      <h1>Buy or Wait?</h1>
      <button onClick={runAnalysis}>Run analysis</button>
    </div>
  );
}
```

## 9. Practical notes for this repo

This project has no existing API server or frontend. So the work is not just deployment — it is a small integration layer.

Recommended minimum change set:

- add `Gemfile`
- add `config.ru`
- add `api/server.rb`
- add `frontend/` React app
- wire frontend to backend API
- deploy backend and frontend separately on Render

## 10. If you want a simpler path

If your goal is only to "make it live" and not build a UI, you can deploy the Ruby logic as a Render background task or one-off job. But for a real product experience, the React + API setup is better.

## 11. Recommended next steps

1. Keep the current Ruby logic as-is.
2. Add a small API wrapper around it.
3. Create a React frontend.
4. Deploy backend and frontend to Render.
5. Add environment variables and CORS configuration.

## 12. Example command flow

```bash
# backend wrapper
bundle install
rackup --host 0.0.0.0 -p 3000

# frontend
cd frontend
npm install
npm run dev
```

## 13. Final answer

Yes, this project can be made live and deployed to Render. The repo is currently a CLI tool, so the right path is:

- wrap the Ruby engine in an API
- add a React frontend
- deploy both separately on Render

This gives you a working product while keeping the core financial decision engine unchanged.

If you want, the next step is to scaffold the actual backend API and React app in the repository.
