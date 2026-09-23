from typing import Type
from urllib.parse import urlparse

from crewai.tools import BaseTool
from pydantic import BaseModel, Field
from ddgs import DDGS


class WebSearchRequest(BaseModel):
    query: str = Field(
        description="Search query for travel research."
    )


class TravelWebSearchTool(BaseTool):
    name: str = "Free web search"

    description: str = (
        "Search the public web for travel information including "
        "attractions, transportation, accommodation, activities, "
        "costs, and travel logistics. Results are filtered to remove "
        "search-engine advertisements and redirect URLs."
    )

    args_schema: Type[BaseModel] = WebSearchRequest

    def _run(self, query: str) -> str:
        try:
            raw_results = list(
                DDGS().text(
                    query,
                    region="in-en",
                    safesearch="moderate",
                    max_results=10,
                )
            )

            results = filter_results(raw_results)

            if not results:
                return (
                    "WEB_SEARCH_RESULT: NO_USEFUL_RESULTS\n"
                    f"Query: {query}\n"
                    f"Raw results received: {len(raw_results)}\n"
                )

            output = (
                "WEB_SEARCH_RESULT: FOUND\n"
                f"Query: {query}\n"
                f"Raw results received: {len(raw_results)}\n"
                f"Useful results returned: {len(results)}\n\n"
            )

            for index, result in enumerate(results, 1):
                output += (
                    f"{index}. {result['title']}\n"
                    f"Source: {result['source']}\n"
                    f"URL: {result['href']}\n"
                    f"Snippet: {result['body']}\n\n"
                )

            return output

        except Exception as exc:
            return (
                "WEB_SEARCH_RESULT: ERROR\n"
                f"Query: {query}\n"
                f"Error: {type(exc).__name__}: {exc}\n"
            )


def filter_results(raw_results: list[dict]) -> list[dict]:

    blocked_domains = {
        "bing.com",
        "www.bing.com",
        "google.com",
        "www.google.com",
        "duckduckgo.com",
        "www.duckduckgo.com",
        "search.yahoo.com",
        "yahoo.com",
        "www.yahoo.com",
    }

    preferred_domains = {
        "visitlondon.com": 10,
        "www.visitlondon.com": 10,
        "incredibleindia.gov.in": 10,
        "www.incredibleindia.gov.in": 10,
        "tripadvisor.com": 8,
        "www.tripadvisor.com": 8,
        "lonelyplanet.com": 8,
        "www.lonelyplanet.com": 8,
        "rome2rio.com": 8,
        "www.rome2rio.com": 8,
        "booking.com": 7,
        "www.booking.com": 7,
        "makemytrip.com": 7,
        "www.makemytrip.com": 7,
        "goibibo.com": 7,
        "www.goibibo.com": 7,
    }

    travel_keywords = [
        "travel",
        "tourism",
        "attractions",
        "things to do",
        "transport",
        "train",
        "bus",
        "flight",
        "hotel",
        "accommodation",
        "itinerary",
        "budget",
        "destination",
    ]

    cleaned = []
    seen_urls = set()

    for result in raw_results:

        href = str(result.get("href", "")).strip()
        title = str(result.get("title", "")).strip()
        body = str(result.get("body", "")).strip()

        if not href or not title:
            continue

        parsed = urlparse(href)
        domain = parsed.netloc.lower()

        if parsed.scheme not in {"http", "https"}:
            continue

        if not domain:
            continue

        if domain in blocked_domains:
            continue

        if "aclick" in parsed.path.lower():
            continue

        if "adurl" in href.lower():
            continue

        if "click?" in href.lower():
            continue

        if "redirect" in parsed.path.lower():
            continue

        normalized_url = href.rstrip("/").lower()

        if normalized_url in seen_urls:
            continue

        seen_urls.add(normalized_url)

        score = preferred_domains.get(domain, 0)

        text = f"{title} {body}".lower()

        score += sum(
            1
            for keyword in travel_keywords
            if keyword in text
        )

        cleaned.append(
            {
                "title": title,
                "href": href,
                "body": body,
                "source": domain,
                "_score": score,
            }
        )

    cleaned.sort(
        key=lambda item: item["_score"],
        reverse=True,
    )

    return [
        {
            "title": item["title"],
            "href": item["href"],
            "body": item["body"],
            "source": item["source"],
        }
        for item in cleaned[:5]
    ]