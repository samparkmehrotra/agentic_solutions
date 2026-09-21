from pathlib import Path

from fastapi import FastAPI
from fastapi.responses import FileResponse
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

from crewai.project import load_crew_and_kickoff


app = FastAPI(
    title="AI Travel Planner",
    description="CrewAI powered travel itinerary generator",
    version="1.0.0",
)

BASE_DIR = Path(__file__).resolve().parent
CREW_FILE = BASE_DIR / "crew.jsonc"
WEB_DIR = BASE_DIR / "web"


app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


class TravelRequest(BaseModel):
    topic: str


@app.get("/")
def home():
    return FileResponse(WEB_DIR / "index.html")


@app.post("/api/plan")
def create_itinerary(request: TravelRequest):

    if not request.topic.strip():
        return {
            "error": "Travel request cannot be empty."
        }

    result = load_crew_and_kickoff(
        str(CREW_FILE),
        {
            "topic": request.topic.strip()
        }
    )

    return {
        "result": result.raw
    }


@app.get("/health")
def health():
    return {
        "status": "healthy"
    }
